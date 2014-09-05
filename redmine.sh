#!/bin/bash

name=redmine.domain.com
ssl_subj="/C=US/ST=Oregon/L=Portland/O=IT/CN=$name"
# uncomment to enable Redmine database and uploaded files backup to AWS S3
# I suggest to setup S3 lifecycle rule for 'redmine-backup-prefix/' to expire old backups
#s3_bucket=bucket-name/redmine-backup-prefix
#access_key=
#secret_key=

set -xe
umask 022

export CFLAGS="-march=native -O2 -pipe"
export CXXFLAGS="$CFLAGS"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y $(cat <<EOP
 curl
 wget
 ntpdate
 rsync
 postfix
 sudo
 pwgen
 tmpreaper
 htop
 nginx
 apache2-utils
 perl
 python
 gcc
 g++
 make
 git
 mercurial
 mysql-server-5.6
 ttf-dejavu-core
 libbz2-dev
 libcurl4-gnutls-dev
 libevent-dev
 libexif-dev
 libfreetype6-dev
 libgmp3-dev
 libicu-dev
 libidn11-dev
 libjasper-dev
 libjpeg-turbo8-dev
 liblcms1-dev
 libmcrypt-dev
 libmysqlclient-dev
 libpcre3-dev
 libpng12-dev
 libssh2-1-dev
 libtiff5-dev
 libxml2-dev
 libxslt1-dev
 libzzip-dev
EOP
)
apt-get clean

curl -L http://www.imagemagick.org/download/ImageMagick.tar.xz |
  xzcat | tar xf -
chown -R 0:0 ImageMagick-*
cd ImageMagick-* &&
  ./configure --enable-static=no --without-magick-plus-plus --with-quantum-depth=16 --disable-docs \
              --with-dejavu-font-dir=/usr/share/fonts/truetype/ttf-dejavu &&
  make -j4 && make install
cd ..

echo "gem: --no-ri --no-rdoc" >> ~/.gemrc
curl -L https://get.rvm.io | bash -s stable
# TODO: after install, prepend to /etc/profile.d/rvm.sh
#id | grep -F '(rvm)' >/dev/null
#if [ $? -eq 0 ]; then
set +x # too much output from rvm function
. /etc/profile.d/rvm.sh
rvm install 1.9.3 -j 4
rvm alias create default 1.9
rvm use 1.9
rvm gemset create redmine
rvm use 1.9@redmine
gem install bundler unicorn
set -x

useradd -s /bin/bash -m -G rvm redmine
chmod o-rwx ~redmine/

mysql_password=$(pwgen 10 1)
echo redmine mysql password: $mysql_password
mysql <<EOF
create database redminedb character set utf8;
create user redmine@localhost identified by '$mysql_password';
grant all privileges on redminedb.* to redmine@localhost;
EOF
echo -e '[mysqld]\nperformance_schema=0' >/etc/mysql/conf.d/mysqld_performance_schema.cnf

mkdir -p /www/blank-page
touch /www/blank-page/index.html

r=/www/$name
mkdir -p $r
curl -L http://www.redmine.org/releases/redmine-2.5.2.tar.gz |
  tar xzo -C $r --strip-components 1 -f -
cat >$r/config/database.yml <<EOF
production:
  adapter: mysql2
  database: redminedb
  host: 127.0.0.1
  username: redmine
  password: $mysql_password
EOF
cat >$r/config/configuration.yml <<EOF
default:
  email_delivery:
    delivery_method: :async_smtp
    async_smtp_settings:
      address: 127.0.0.1
      port: 25
EOF
cd $r
echo -e '\ngem "unicorn"' >> Gemfile
bundle install --without development test
rake generate_secret_token
RAILS_ENV=production rake db:migrate
RAILS_ENV=production REDMINE_LANG=en rake redmine:load_default_data
mkdir -p public/plugin_assets

cat >$r/config/unicorn.rb <<EOF
worker_processes 5
working_directory "$r"
preload_app true
timeout 30
listen "$r/tmp/sockets/unicorn.sock", :backlog => 64
pid "$r/log/unicorn.pid"
stderr_path "$r/log/unicorn.err"
stdout_path "$r/log/unicorn.log"

before_fork do |server, worker|
    defined?(ActiveRecord::Base) and
        ActiveRecord::Base.connection.disconnect!
end

after_fork do |server, worker|
    defined?(ActiveRecord::Base) and
        ActiveRecord::Base.establish_connection
end
EOF

cat >~redmine/unicorn.sh <<EOF
#!/bin/sh
exec unicorn_rails -c config/unicorn.rb -E production -D
EOF
chmod +x ~redmine/unicorn.sh

chown -R redmine:redmine $r
ln -s $r ~redmine/
chown -h redmine:redmine ~redmine/*

crontab -u redmine - <<EOF
MAILTO=root
SHELL=/bin/bash
@reboot cd \$HOME/$name && . /etc/profile.d/rvm.sh && rvm use 1.9@redmine && \$HOME/unicorn.sh
*/10 * * * * cd \$HOME/$name && . /etc/profile.d/rvm.sh && rvm use 1.9@redmine && ruby script/rails runner "Repository.fetch_changesets" -e production
EOF

mkdir -p /etc/nginx/ssl
openssl req -new -nodes -x509 -days 10000 \
  -subj "$ssl_subj" \
  -keyout /etc/nginx/ssl/$name.key -out /etc/nginx/ssl/$name.crt -extensions v3_ca
chmod -R go-rwx /etc/nginx/ssl

cat >/etc/nginx/nginx.conf <<EOF
user  www-data;
worker_processes  1;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    access_log    /var/log/nginx/access.log;

    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout  30;
    gzip            on;
    gzip_types      text/css text/plain application/x-javascript application/xml; # text/html is already included in the list
    client_max_body_size   64M;
    client_body_temp_path  /var/tmp;

    server {
        listen       *:80 default_server;
        server_name  unset;
        root         /www/blank-page;
    }

    server {
        listen       *:80;
        server_name  $name;
        root         $r/public;
        rewrite    ^ https://$name permanent;
    }
    upstream redmine {
        server  unix:$r/tmp/sockets/unicorn.sock;
    }
    server {
        listen       *:443 default_server ssl;
        server_name  $name;
        root         $r/public;

        ssl_certificate      ssl/$name.crt;
        ssl_certificate_key  ssl/$name.key;

        location / {
            if (!-f \$request_filename) {
                proxy_pass  http://redmine;
                break;
            }
        }
    }
}
EOF

service nginx start

rm -f /etc/cron.daily/tmpreaper

wget --no-check-certificate -O /usr/local/bin/aws2 https://raw.github.com/timkay/aws/master/aws
chmod +x /usr/local/bin/aws2
cat >/root/.awssecret <<EOF
$access_key
$secret_key
EOF
chmod 600 /root/.awssecret
cat >/usr/local/sbin/redmine-backup.sh <<EOF
#!/bin/sh
s3_bucket="$s3_bucket"
test -n "\$s3_bucket" || exit 0
mysqldump -e redminedb | bzip2 | /usr/local/bin/aws2 put \$s3_bucket/\$(date +%Y%m%d)-database.sql.bz2
cd $r && tar cj files | /usr/local/bin/aws2 put \$s3_bucket/\$(date +%Y%m%d)-files.tar.bz2
EOF
chmod +x /usr/local/sbin/redmine-backup.sh

crontab - <<EOF
17 1 * * * /usr/sbin/ntpdate europe.pool.ntp.org >/dev/null
18 1 * * * /usr/local/sbin/redmine-backup.sh
 3 * * * * /usr/sbin/tmpreaper --mtime 20m --protect "/tmp/passenger*/*/*" /tmp
 4 * * * * /usr/sbin/tmpreaper --mtime 2h /var/tmp
EOF

cat >>/etc/fstab <<EOF
tmpfs           /tmp            tmpfs   size=1G                   0       0
tmpfs           /var/tmp        tmpfs   size=1G                   0       0
EOF

echo "Reboot now to start Rails Unicorn processes"
