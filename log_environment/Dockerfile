FROM alpine:3.20

RUN apk add --no-cache elixir logrotate

WORKDIR /opt/beamwatch-log-environment

COPY lib/beamwatch/log_feed ./lib/beamwatch/log_feed
COPY log_environment/logrotate.conf /etc/logrotate.d/beamwatch
COPY log_environment/run.sh ./run.sh

RUN chmod +x ./run.sh

CMD ["/opt/beamwatch-log-environment/run.sh"]
