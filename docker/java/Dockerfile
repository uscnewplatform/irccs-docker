FROM openjdk:17-jdk-slim
MAINTAINER Salvatore Turboli (salvatore.turboli@infocube.it)
RUN apt-get update && apt-get install -y dos2unix iputils-ping curl
COPY scripts/start.sh /start.sh
RUN dos2unix /start.sh
CMD ["bash","/start.sh"]