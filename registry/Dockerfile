FROM openjdk:17-jdk-slim
WORKDIR /app
ARG folder
COPY $folder/ /app/
RUN apt-get update && apt-get install -y dos2unix iputils-ping curl
COPY script/start.sh /app/
RUN dos2unix /app/start.sh
CMD ["bash","/app/start.sh"]