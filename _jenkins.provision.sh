#! /bin/bash

set -e
set -x

sudo aptitude update
sudo aptitude -y safe-upgrade

sudo aptitude install -y ruby1.9.1 ruby1.9.1-dev build-essential wget libruby1.9.1 rubygems
sudo gem1.9.1 update --no-rdoc --no-ri
sudo gem1.9.1 install ohai chef --no-rdoc --no-ri

# Jenkins will need librarian-chef to provision new AMIs in jobs using chef provisioning
sudo gem1.9.1 install --no-rdoc --no-ri librarian

# set the attributes file
cat > /etc/chef/attributes.json <<EOC
{
  "run_list": [
    "role[jenkins]"
  ]
}
EOC