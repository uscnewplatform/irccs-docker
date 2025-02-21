### How to configure you local env

if you want to have access to the docker registry follow this step

- Add nexus host in your docker conf:
    - if you using windows: Docker Desktop > Settings > Docker Engine and add to json:  `"insecure-registries": ["nexus.infocube.it:8089"]`
    - if you usig linux: Edit to `/etc/docker/daemon.json` (default is not exists) and add `{"insecure-registries": ["nexus.infocube.it:8089"]}`
- Run docker login: `docker login -u docker_service_user nexus.infocube.it:8089`

insert a secret password, if you don't have a password, ask your infocube sys.