# Photon (place search and address lookup) for the office NAS (see
# ../README.md). The same image serves the search and, during the weekly
# refresh, imports it from the temporary Nominatim database.
FROM eclipse-temurin:21.0.11_10-jre-jammy

ARG PHOTON_VERSION=0.6.2
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /photon \
 && curl -fsSL -o /photon/photon.jar \
    "https://github.com/komoot/photon/releases/download/${PHOTON_VERSION}/photon-${PHOTON_VERSION}.jar"

RUN useradd --system --create-home photon && mkdir -p /data && chown photon /data
USER photon
WORKDIR /data

# The search for Malaysia, Singapore and Brunei fits in 1 GB of Java heap;
# the compose file caps the container at 2 GB.
ENV JAVA_TOOL_OPTIONS="-Xms512m -Xmx1g"
EXPOSE 2322
ENTRYPOINT ["java", "-jar", "/photon/photon.jar"]
CMD ["-data-dir", "/data", "-listen-ip", "0.0.0.0", "-listen-port", "2322"]
