FROM boky/postfix

RUN apt-get update && apt-get install -y inotify-tools

COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
CMD [ "/usr/local/bin/entrypoint.sh" ]
