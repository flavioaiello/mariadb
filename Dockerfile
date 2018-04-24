FROM debian:stretch-slim

ENV MARIADB_MAJOR 10.2
ENV MARIADB_VERSION 10.2.14+maria~stretch

RUN set -ex ;\
    groupadd -r mysql ;\
    useradd -r -g mysql mysql ;\
    { \
       echo "mariadb-server-${MARIADB_MAJOR}" mysql-server/root_password password 'unused' ;\
       echo "mariadb-server-${MARIADB_MAJOR}" mysql-server/root_password_again password 'unused' ;\
    } | debconf-set-selections ;\
    echo "deb http://ftp.osuosl.org/pub/mariadb/repo/${MARIADB_MAJOR}/debian stretch main" > /etc/apt/sources.list.d/mariadb.list ;\
    apt-get update ;\
    apt-get install -y --allow-unauthenticated --no-install-recommends ca-certificates pwgen "mariadb-server=${MARIADB_VERSION}" netcat ;\
    rm -rf /var/lib/apt/lists/* /var/lib/mysql ;\
    mkdir -p /docker-entrypoint-initdb.d /var/lib/mysql /var/run/mysqld ;\
    chown -R mysql:mysql /var/lib/mysql /var/run/mysqld ;\
    chmod 777 /var/run/mysqld ;\
    sed -re 's/^(bind-address|log|user)/#&/' \ 
        -e '/wait_timeout[^_]\s*/c\wait_timeout = 750' \
        -e '/\[mysqld\]/a skip-host-cache' \
        -e '/\[mysqld\]/a skip-name-resolve' \
        -i /etc/mysql/my.cnf

# Add local files to image
COPY files /

VOLUME ["/var/lib/mysql"]
EXPOSE 3306
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["mysqld","--user=mysql","--console"]
