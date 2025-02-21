#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <input_string>"
    exit 1
fi

# Use the provided string as the folder name
image="$1"

# Create a directory if not exists
if [[ ! -e $image ]]; then
    echo "$image folder not exists, create a empty folder"
    mkdir $image
fi


# Build micro-service from github
cd $image
git clone git@github.com:infocube-it/$image.git tmp
cd tmp/
git checkout master
mvn package -DskipTests
cd ..
cp -r tmp/target/quarkus-app/* .
rm -rf tmp/
cd ..

docker build  --no-cache -t "$image":latest --build-arg folder=$image .

echo "Docker image '$image' has been built successfully."

docker login -u docker_service_user -p Infocube123 nexus.infocube.it:8089
docker tag $image:latest nexus.infocube.it:8089/i3/irccs/$image
docker push nexus.infocube.it:8089/i3/irccs/$image
docker tag $image:latest nexus.infocube.it:8089/i3/irccs/$image
docker push nexus.infocube.it:8089/i3/irccs/$image
rm -rf $image
