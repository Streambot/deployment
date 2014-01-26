#!/bin/bash

################################################################################
# This software is licensed under the MIT License (MIT)
#
# Copyright (c) 2013 Martin Biermann
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
################################################################################


if [ "$DEBUG" != "true" ]; then
  DEBUG=false
else
  set -x
fi
echo "--> Debug mode: $DEBUG"
set -e

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
  ec2Cmd="aws ec2 run-instances \
 --image-id $AMI_ID \
 --security-group-ids $SG_ID \
 --instance-type $INSTANCE_TYPE \
 --subnet-id $SUBNET $BLOCK_DEVICE_MAPPING \
 --key-name $KEY_PAIR_NAME"
  echo "--> Command: $ec2Cmd"
  response=`$ec2Cmd`
  instanceId=`echo "$response" | grep InstanceId | sed 's/.*"InstanceId": "\(.*\)".*/\1/'`
  privateIp=`echo "$response" | grep PrivateIpAddress | sed -n 's/.*"PrivateIpAddress":[^"]*"\([^"]*\)".*/\1/p' | head -1`

  [ "$instanceId" = "" ] && echo "Could not read Instance ID" && exit 1
  [ "$privateIp" = "" ] && echo "Could not read Private IP Address" && exit 1

  # Now we tag the intstance with ``Name``. Actually name is
  # not that important here since we terminate the instance afterwards.
  aws ec2 create-tags --resources $instanceId --tag Key=Name,Value=${INSTANCE_NAME} > /dev/null
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

  # Ensure a clean work space by deleting any previous located directory there
  rm -rf $CWD

  mkdir -p $CWD/tmp
  cd $CWD/tmp
  # Check out the correct branch if given
  git clone $CHEF_GIT --branch $GIT_BRANCH
  chef_dir=`echo $CHEF_GIT | sed 's/.*\/\([^\/\.]*\)\.git/\1/g'`
  
  cd $chef_dir
  # Its safe to call the submodule commands here
  # even if the repos does not have any of these.
  git submodule init
  git submodule update

  cp $BERKSHELF_SRC/"${CHEF_ROLE}.berksfile" Berksfile
  berks install --path cookbooks

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
  tar czf chef.tar.gz environments/ roles/ cookbooks/ #site-cookbooks/ #data_bags/

  # Now copy the chef tarball to the instance
  remote_call "sudo mkdir -p /var/chef/"
  remote_send chef.tar.gz /tmp/
  remote_call "sudo tar -xzf /tmp/chef.tar.gz -C /var/chef/"

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

  remote_call "sudo aptitude update"
  remote_call "sudo aptitude -y safe-upgrade"

  # Now we inject the correct/given provisioning script to the machine
  echo "--> Upload Chef attributes"
  ATTRIBUTES=`cat ${CHEF_ROLE}.attributes.json`
  if [ "$CHEF_ROLE" = "api" ]; then
    ATTRIBUTES=`echo $ATTRIBUTES | sed "s/#{API_REXSTER_HOST}/$API_REXSTER_HOST/"`
  fi
  ATTRIBUTES=`echo $ATTRIBUTES | sed "s/#{AWS_INSTANCE_SERVICE}/$AWS_INSTANCE_SERVICE/"`
  ATTRIBUTES=`echo $ATTRIBUTES | sed "s/#{AWS_INSTANCE_ENV}/$AWS_INSTANCE_ENV/"`
  echo $ATTRIBUTES > attributes.json
  if [ "$DEBUG" != "true" ] cat attributes.json
  remote_send attributes.json /etc/chef/attributes.json
  remote_call "sudo chef-solo -c /etc/chef/solo.rb -j /etc/chef/attributes.json -l debug"
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
  create_ami_cmd="aws ec2 create-image \
  --instance-id $instanceId \
  --name ${INSTANCE_NAME}-${VERSION}"
  echo "--> Command: $create_ami_cmd"
  response=`$create_ami_cmd`
  amiId=`echo "$response" | grep ImageId | sed 's/.*"ImageId": "\(.*\)".*/\1/'`

  [ "$amiId" = "" ] && echo "Could not read AMI ID" && exit 1

  # The create-ami api tool will immediately return and we need to check ourselfs
  # whether ami creation is done successfully. Therefore we poll every 1 min (AMI_EXIST_CHECK_INTERVAL)
  # the current status of the ami.
  amiCheckCmd="aws ec2 describe-images --image-ids $amiId"
  echo "--> Command: $amiCheckCmd"
  amiStatus=`echo \`$amiCheckCmd\` | grep '"State":' | sed -n 's/.*"State":[^"]*"\([^"]*\)".*/\1/p' | head -1`
  until [ "$amiStatus" = "available" ]; do
    sleep $AMI_EXIST_CHECK_INTERVAL
    amiStatus=`echo \`$amiCheckCmd\` | grep '"State":' | sed -n 's/.*"State":[^"]*"\([^"]*\)".*/\1/p' | head -1`
    # To verify we don't stuck in an endless loop we check possible states here.
    # The amiStatus must be one of ['pending', 'available']
    case $amiStatus in
      pending) ;;
      available) ;;
      *) echo "unknown state $amiState" && exit 1;;
    esac
  done
}

function read_args {
  h "Reading arguments"

  while [[ $# > 1 ]]
  do
    key="$1"
    shift
    if [ "$key" = "--no-terminate" ]; then
      TERMINATE=false
      continue
    fi
    case $key in
      -c|--berkshelf-src) BERKSHELF_SRC="$1" ;;
      -b|--git-branch) GIT_BRANCH="$1" ;;
      -p|--key-pair) KEY_PAIR="$1" ;;
      -d|--key-pair-name) KEY_PAIR_NAME="$1" ;;
      -n|--instance-name) INSTANCE_NAME="$1" ;;
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
  CWD="create_ami_${INSTANCE_NAME}_`date -u | sed -e 's/\ /-/g'`"
  echo "--> Terminate: ${TERMINATE}"
  echo "--> Berkshelf sources: ${BERKSHELF_SRC}"
  echo "--> Git branch: ${GIT_BRANCH}"
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

# Here we will cleanup everything after ami was created.
# This basically means to run all pending stack commands.
function clean_up {
  h "Cleaning up"
  # Before calling deactivate the strict check for the commands return values (`set -e`) 
  # so that commands do not interfere.
  set +e
  # If there is an instanceId, terminate the instance referenced by the ID
  if [ "$TERMINATE" = "true" -a "$instanceId" != "" ]; then
    aws ec2 terminate-instances --instance-ids $instanceId > /dev/null
  fi
  # Now get back to strict check mode
  set -e
  # Remove the working directory
  rm -rf $CWD
}

# On ir-/regular exit, invoke clean up
trap '{ clean_up; }' EXIT SIGINT SIGTERM

# Lets start ;)
read_args $@
start_instance
remote_test
setup_instance $@
test_instance
generate_ami $@

# echo ami id to easily copy jenkins output
echo "AMI-ID: $amiId"
echo "SUCCESS"