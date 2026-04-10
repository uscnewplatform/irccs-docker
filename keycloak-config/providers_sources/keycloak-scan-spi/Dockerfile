FROM quay.io/keycloak/keycloak:25.0.6

# Copy the built SPI JAR into Keycloak's providers directory.
# Keycloak auto-discovers all JARs in this directory on startup.
COPY target/keycloak-scan-spi-1.0.0.jar /opt/keycloak/providers/

# kc.sh build compiles the Quarkus application with the new providers included.
# This must be done at image-build time (not at runtime) for production images.
RUN /opt/keycloak/bin/kc.sh build

# Standard Keycloak environment — override in docker-compose / k8s
ENV KC_DB=postgres
ENV KC_HTTP_ENABLED=true
ENV KC_HOSTNAME_STRICT=false

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start"]
