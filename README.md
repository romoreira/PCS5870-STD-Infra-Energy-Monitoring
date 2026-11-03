ssh -F ssh_config -i slice_key -N -o ExitOnForwardFailure=yes -L 3000:10.30.6.94:30000 -L 2333:10.30.6.94:30001 ubuntu@2001:48d0:6031:1991:f816:3eff:fee2:e44a
