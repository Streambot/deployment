#!/bin/bash

################################################################################
# The MIT License (MIT)
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

# A provisioning bash script to setup the final variables on a service instance.

# Determine the IP address of the machine
internalIp=`ifconfig eth0 | grep 'inet addr' | awk '{print $2}' | cut -d: -f2`
internalIp=${internalIp//./-}

# Update the chef solo provisioning meta data to put the IP address in the node name and set the 
# chef environment to production
cat > /etc/chef/solo.rb <<EOC
node_name "prod-eu-api-$internalIp"
environment "production"
EOC

# Run chef solo to put the final data into action
chef-solo -j /etc/chef/attributes.json