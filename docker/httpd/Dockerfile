FROM httpd:2.4.46
MAINTAINER Salvatore Turboli (salvatore.turboli@infocube.it)
RUN mkdir -p /usr/local/apache2/conf/sites/
COPY conf/httpd.conf /usr/local/apache2/conf/httpd.conf
COPY conf/irccs.conf /usr/local/apache2/conf/sites/irccs.conf
RUN mkdir -p /usr/local/apache2/cert
RUN apt-get update
RUN apt-get install -y certbot python-certbot-apache
EXPOSE 80
CMD ["httpd", "-D", "FOREGROUND"]