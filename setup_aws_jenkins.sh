#! /bin/bash

./create_ami.sh --instance-type t1.micro --subnet-id subnet-1c88807e --security-group-id sg-1fecfa7d --ami-id ami-07cb2670 --region eu-west-1 --chef-git git@bitbucket.org:streambot/chef.git --chef-env production --chef-role jenkins --aws-key AKIAIEJPGPNLNM2YAGTA --aws-secret-key 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 --instance-name Jenkins --key-pair ~/Dropbox/channel/aws/martin_biermann.pem --key-pair-name martin_biermann
