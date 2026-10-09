#!/bin/bash

echo "runnig dev : (docker,posgress,redis,kafka,app server)"

#stop docker
bash ./infrastructure/dev/stop-dev.sh 
#start docker
bash ./infrastructure/dev/run-dev.sh

# echo "cleaning complied dep"
# bash ./clean-compile

echo "building project"
bash ./build.sh