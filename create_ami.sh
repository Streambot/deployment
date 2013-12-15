#!/bin/bash

set -e
# set -x

#/ Expected environmental variables:
#/  AMI_ID:             The ami id for a vanilla ubuntu.
#/  SG_ID:              The security group id.
#/  INSTANCE_TYPE:      The aws instance type - ex. m1.large.
#/  SUBNET:             The subnet id.
#/  ROOT_SIZE:          The size for your root volume. If not specified this will not be changed.
#/  REGION:             The aws region where the instance is spawned.
#/  ACCEPTANCE_TEST:    The script called after the provisioning to check that the ami is valid!
#/  CHEF_GIT:           The git url for the chef-repository that will be injected.
#/  CHEF_ROLE:          The chef role that will be provisioned.
#/  CHEF_ENV:           The chef environment set in your solo.rb file.
#/  GIT_BRANCH:      The chef branch that will be checked out. If not set this will be reset to master.
#/  VERSION:            The version of the ami. This will be part of the name. If one does not specify the parameter the current date (%Y-%m-%d-%H-%M) will be taken.
#/

INSTANCE_NAME=
KEY_PAIR=
KEY_PAIR_NAME=
AWS_KEY=
AWS_SECRET_KEY=
INSTANCE_TYPE=
SUBNET=
SG_ID=
AMI_ID=
REGION=
CHEF_GIT=
CHEF_ENV=
CHEF_ROLE=
CWD=
SSH_TIMEOUT="300"
SSH_ATTEMPTS="3"
SSH_TRIES="30"

# Check the VERSION and give it a default value if not set.
[ "$VERSION" == "" ] && VERSION=`date +%Y-%m-%d-%H-%M`

# The recheck interval we test whether the ami was created successfully
AMI_EXIST_CHECK_INTERVAL="60"


# check the ROOT_SIZE and define the BLOCK_DEVICE_MAPPING therefore.
if [ "$ROOT_SIZE" == "" ]; then
  BLOCK_DEVICE_MAPPING=""
else
  BLOCK_DEVICE_MAPPING="-b /dev/sda1=:$ROOT_SIZE"
fi

# The chef checkout should always be set to master if not given.
[ "$GIT_BRANCH" == "" ] && GIT_BRANCH="master"

function h {
  echo ""
  echo "> $1"
  echo "============================================================"
}

# This function is small helper to execute your command on the
# remote machine. Here we also add some options to ssh like:
# - ConnectionAttempts:
#     We want to try reach ssh more than 1 time if connection is lost shortly
# - ConnectionTimeout:
#     We want to wait at least 5 min before canceling the connection.
#     If we just launched an instance it may take some minutes before the machine
#     is booted and sshd is up - therefore a high timeout is necessary.
# - StrictHostKeyChecking=no :
#     We don't want to varify ssh key since here we must type ``YES`` and this
#     is a script so there should be no stdin inlcuded.
# - UserKnownHostsFile=/dev/null
#     We don't want to store the ssh to the known_hosts file since we do fire up
#     machines and delete them often. This will lead to machines with same ip addresses
#     so ssh will grumble if we see a machine with the same ip but different ssh.keys .
#
# @param $1 {string} The command executed on the remote host.
function remote_call {
  ssh -i $KEY_PAIR -o ConnectionAttempts=$SSH_ATTEMPTS -o ConnectTimeout=$SSH_TIMEOUT \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$privateIp "$@"
}

# With this funciton we will test whether the sshd is up and running. We expect that
# our ssh key is installed as user ubuntu. In some cases it is possible that the sshd
# is up and running but still declines connections therefor a simple ssh with waitign is
# not enough, but rather we must try to connect several times.
#
# For simplicity we do an ``echo OK`` on the remote host using the ssh command in remote_call
# (We should not call remote_call directly since the ``set -e`` option might exit our call).
# But we will do this in a loop with at ``$SSH_TRIES`` calls.
function remote_test {
  h "Waiting for SSH access"
  for i in `seq $SSH_TRIES`; do
    if [ "`ssh -i $KEY_PAIR -o ConnectionAttempts=$SSH_ATTEMPTS \
      -o ConnectTimeout=$SSH_TIMEOUT \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      ubuntu@$privateIp \"echo OK\"`" = "OK" ]; then
      echo "Connection granted"
      return
    else
      sleep 10
    fi
  done
  echo "Could not get a connection within $SSH_TRIES tries." && exit 1
}

# This function will send a local file to the remote host.
# This will also add some options to the ssh call (see remote_call for descriptions).
#
# @param $1 {string} The local file taken.
# @param $2 {string} The remote location.
function remote_send {
  scp \
  -i $KEY_PAIR \
  -o ConnectionAttempts=$SSH_ATTEMPTS \
  -o ConnectTimeout=$SSH_TIMEOUT \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  $1 \
  ubuntu@$privateIp:$2
}

# This function will start one instance with the given ``ENV`` varaiables.
# It also tags it with a name.
# When launching the machine was successful the following variables are available:
# - instanceId
# - privateIp
function start_instance {
  h "Starting instance"
  # Create an instance and ...
  ec2Cmd="ec2-run-instances $AMI_ID --aws-access-key $AWS_KEY \
  --aws-secret-key $AWS_SECRET_KEY -g $SG_ID -t $INSTANCE_TYPE \
  --subnet $SUBNET $BLOCK_DEVICE_MAPPING --region $REGION --key $KEY_PAIR_NAME"
  echo "--> Command: $ec2Cmd"
  DATA=`$ec2Cmd | egrep '(INSTANCE|PRIVATEIPADDRESS)' | awk '{print $1","$2}'`

  # ... parse the output to get the instance-id and -ip
  for line in $DATA; do
    if [[ $line =~ INSTANCE ]]; then
      instanceId=`echo $line | awk -F, '{print $2}'`
    elif [[ $line =~ PRIVATEIPADDRESS ]]; then
      privateIp=`echo $line | awk -F, '{print $2}'`
    fi
  done

  [ "$instanceId" = "" ] && echo "Could not read INSTANCE" && exit 1
  [ "$privateIp" = "" ] && echo "Could not read PRIVATEIPADDRESS" && exit 1

  # Now we tag the intstance with ``Name``. Actually name is
  # not that important here since we terminate the instance afterwards.
  ec2-create-tags $instanceId --tag Name=${INSTANCE_NAME} \
  --region $REGION --aws-access-key $AWS_KEY --aws-secret-key $AWS_SECRET_KEY
}

# This function will provision the instance, which means:
# - get the latest debian packages
# - install chef-solo(-client)
# - copy the chef cookbooks to the target host
# - send the individual job script to the target and execute it there
#   - Make sure your job script writes its run list to the attributes.json
#     file, which is located at /etc/chef/attributes.json, because the
#     following chef-solo call will use exactly this file!
# - finally we call chef-solo on the host!
function setup_instance {
  h "Setting up instance"
  # Update all the ubuntu packages at the beginning so we have
  # a clean up-2-date machine.
  remote_call "sudo apt-get update && sudo apt-get dist-upgrade -y"

  # lets install chef-solo to the instance
  remote_call "curl -L https://www.opscode.com/chef/install.sh | sudo bash"

  # Now we inject the chef repository to the instance.
  rm -rf $CWD
  # Check out the correct branch if given
  git clone $CHEF_GIT --branch $GIT_BRANCH
  
  cd $CWD
  # Its safe to call the submodule commands here
  # even if the repos does not have any of these.
  git submodule init
  git submodule update

  cat _Cheffile "_${CHEF_ROLE}.cheffile" > Cheffile
  librarian-chef install
  ls

  # We now generate a tarball out of the chef repository.
  # Since chef-solo can only handle:
  # - cookbooks
  # - data_bags
  # - environments
  # - roles
  # We will only copy these folders to the machine.
  # Make sure your repository has this folder structure - otherwise this
  # might not work! We don't need to delete old tarballs since tar itself
  # will override an existing file called chef.tar.gz.
  tar czf chef.tar.gz environments/ roles/ cookbooks/ site-cookbooks/ #data_bags/

  # Now copy the chef tarball to the instance
  remote_call "sudo mkdir -p /var/chef/"
  remote_send chef.tar.gz /tmp/
  remote_call "sudo tar -xzf /tmp/chef.tar.gz -C /var/chef/"
  cd ../

  # Generate solo.rb
  echo "--> Setting up solo.rb"
  remote_call "sudo mkdir -p /etc/chef/"
  remote_call "cat <<EOC | sudo tee /etc/chef/solo.rb
role_path '/var/chef/roles'
environment_path '/var/chef/environments'
environment '${CHEF_ENV}'
node_name '${INSTANCE_NAME}'
cookbook_path ['/var/chef/cookbooks','/var/chef/site-cookbooks']
EOC"

  # Create an attributes configuration file to initialize chef-solo provisioning
  echo "--> Set up chef attributed config JSON file"
  remote_call "sudo touch /etc/chef/attributes.json"
  remote_call "sudo chown ubuntu /etc/chef/attributes.json"

  # Now we inject the correct/given provisioning script to the machine
  echo "--> Run custom provision script"
  remote_send "_${CHEF_ROLE}.provision.sh" /tmp/provision.sh
  # After injection is done, we simple call the provisioning script.
  remote_call "bash /tmp/provision.sh $@"

  echo "--> Running Chef Solo"
  # Now there must be a file created at /root/attributes.json which will now
  # be called with chef-solo
  remote_call "sudo chef-solo -c /etc/chef/solo.rb -j /etc/chef/attributes.json"
}

# This one will test whether our ami is ready to be created.
function test_instance {
  if [ "$ACCEPTANCE_TEST" != "" ]; then
    remote_send $ACCEPTANCE_TEST /tmp/test.sh
    remote_call "bash /tmp/test.sh"
  fi
}

# After our machine is provisioned we call this function to create an AMI.
# After this function is called the following variables are available:
# - amiId - The aws ami id.
function generate_ami {
  h "Generating AMI"
  # make an image of the instance and ...
  amiCmd="ec2-create-image $instanceId --name ${INSTANCE_NAME}-${VERSION} --region $REGION \
  --aws-access-key $AWS_KEY --aws-secret-key $AWS_SECRET_KEY"
  DATA=`$amiCmd | egrep '(IMAGE)' | awk '{print $1","$2}'`

  # ... parse the output to get the amiId
  for line in $DATA; do
    if [[ $line =~ IMAGE ]]; then
      amiId=`echo $line | awk -F, '{print $2}'`
    fi
  done

  [ "$amiId" = "" ] && echo "Could not read IMAGE" && exit 1

  # The create-ami api tool will immediately return and we need to check ourselfs
  # whether ami creation is done successfully. Therefore we poll every 1 min (AMI_EXIST_CHECK_INTERVAL)
  # the current status of the ami.
  amiCheckCmd="ec2-describe-images $amiId --region $REGION --aws-access-key $AWS_KEY \
  --aws-secret-key $AWS_SECRET_KEY"
  amiStatus=`$amiCheckCmd | egrep IMAGE | awk '{print $5}'`
  until [ "$amiStatus" = "available" ]; do
    sleep $AMI_EXIST_CHECK_INTERVAL
    amiStatus=`$amiCheckCmd | egrep IMAGE | awk '{print $5}'`
    # To verify we don't stuck in an endless loop we check possible states here.
    # The amiStatus must be one of ['pending', 'available']
    case $amiStatus in
      pending) ;;
      available) ;;
      *) echo "unknown state $amiState" && exit 1;;
    esac
  done
}

# Here we will cleanup everything after ami was created.
function clean_up {
  # From now we are only deleting the instance again.
  ec2-terminate-instances $instanceId --region $REGION --aws-access-key $AWS_KEY \
  --aws-secret-key $AWS_SECRET_KEY
}


function read_args {
  h "Reading arguments"

  while [[ $# > 1 ]]
  do
    key="$1"
    shift
    case $key in
      -b|--git-branch) GIT_BRANCH="$1" ;;
      -p|--key-pair) KEY_PAIR="$1" ;;
      -d|--key-pair-name) KEY_PAIR_NAME="$1" ;;
      -n|--instance-name) INSTANCE_NAME="$1" ;;
      -k|--aws-key) AWS_KEY="$1" ;;
      -c|--aws-secret-key) AWS_SECRET_KEY="$1" ;;
      -i|--instance-type) INSTANCE_TYPE="$1" ;;
      -s|--subnet-id) SUBNET="$1" ;;
      -g|--security-group-id) SG_ID="$1" ;;
      -a|--ami-id) AMI_ID="$1" ;;
      -r|--region) REGION="$1" ;;
      -e|--chef-env) CHEF_ENV="$1" ;;
      -g|--chef-git) CHEF_GIT="$1" ;;
      -x|--chef-role) CHEF_ROLE="$1" ;;
      *) ;;
    esac
    shift
  done
  # filter the repo name from the git_chef
  echo "--> Instance name: ${INSTANCE_NAME}"
  CWD=`echo $CHEF_GIT | sed 's/git@bitbucket.org:streambot\/\([^.]*\)\.git/\1/g'`
  echo "--> Git branch: ${GIT_BRANCH}"
  echo "--> AWS key: ${AWS_KEY}"
  echo "--> AWS secret key: ${AWS_SECRET_KEY}"
  echo "--> Key pair: ${KEY_PAIR}"
  echo "--> Key pair name: ${KEY_PAIR_NAME}"
  echo "--> Instance type: ${INSTANCE_TYPE}"
  echo "--> Subnet ID: ${SUBNET}"
  echo "--> Security group ID: ${SG_ID}"
  echo "--> AMI ID: ${AMI_ID}"
  echo "--> Region: ${REGION}"
  echo "--> Chef environment: ${CHEF_ENV}"
  echo "--> Chef role: ${CHEF_ROLE}"
  echo "--> Chef git repository: ${CWD}"
  echo "--> SSH max tries: ${SSH_TRIES}"
  echo "--> SSH timeout: ${SSH_TIMEOUT}"
  echo "--> SSH max connection attempts: ${SSH_ATTEMPTS}"
}

# Lets start ;)
read_args $@
start_instance
remote_test
setup_instance $@
test_instance
generate_ami $@
clean_up

# echo ami id to easily copy jenkins output
echo "AMI-ID: $amiId"
echo "SUCCESS"