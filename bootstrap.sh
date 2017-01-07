#!/usr/bin/env bash

# Where WordPress will be installed.
web_root="/var/www/html"

# Database credentials
db_name="wordpress"
db_user="wordpressuser"
db_pass="wordpresspass"

# Define required packages
packages=(
  apache2
  libapache2-mod-php
  mariadb-client
  mariadb-server
  php
  php-mysql
  phpunit
  subversion
)

# Check if required packages are installed. If not, install them.
dpkg -s ${packages[*]} &>/dev/null
if [ $? -eq 1 ]; then
  echo "Installing packages...";
  apt-get update
  apt-get install -y ${packages[*]}
fi

# Configure the database, if it has not already been configured.
if [ ! -f /var/log/databasesetup ]; then
  echo "Configuring the database..."

  # Define MySQL client command and the queries to run (in order).
  # MySQL root's password is '' (empty; no password).
  mysql_client="sudo mysql -uroot"
  mysql_commands=(
    "CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}'"
    "CREATE DATABASE ${db_name}"
    "GRANT ALL ON ${db_name}.* TO '${db_user}'@'localhost'"
    # Allow Linux users other than root to login to MySQL root account
    # (needed for bootstrapping PHPUnit).
    "UPDATE mysql.user SET PLUGIN = 'mysql_native_password' WHERE User='root'"
    "FLUSH PRIVILEGES"
  )

  for query in "${mysql_commands[@]}"; do
    echo $query | ${mysql_client}
    if [ $? -ne 0 ]; then
      >&2 echo "Database setup failed. The failed query was:"
      >&2 echo -e "\t${query}"
      exit 1
    fi
  done

  echo "Successfully configured the database."
  touch /var/log/databasesetup
fi

# Configure apache2
if [ ! -f /var/log/webserversetup ]; then
  echo "Configuring Apache..."

  # Set up modules.
  #   mpm_event was causing issues with php7.0 (not threadsafe), \
  #   so I switched over to mpm_prefork
  a2dismod mpm_event
  a2enmod mpm_prefork
  a2enmod php7.0
  a2enmod rewrite
  systemctl restart apache2

  # Configure Apache
  sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf
  if [ $? -eq 1 ]; then
    >&2 echo "Failed to enable override in the apache configuration."
    exit 1
  fi

  echo "Successfully configured Apache."
  touch /var/log/webserversetup
fi

# Install wp-cli.
if [ ! -x /usr/local/bin/wp ]; then
  echo "Installing wp-cli..."
  wp_cli_url="https://raw.github.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"

  wget -O /usr/local/bin/wp ${wp_cli_url}
  if [ $? -ne 0 ]; then
    >&2 echo "Failed to download wp-cli from ${wp_cli_url}"
    exit 1
  fi

  chmod a+x /usr/local/bin/wp
  echo "Successfully installed wp-cli."
fi

# Set up WordPress.
if [ ! -f /var/log/wordpress ]; then
  echo "Setting up WordPress..."

  test_data_url="https://raw.githubusercontent.com/manovotny/wptest/master/wptest.xml"
  wp_command="sudo -u www-data wp"

  # Set up web directory.
  cd ${web_root}
  rm -rf *
  chown -R www-data:www-data .

  # Install WordPress
  wp_install=(
    "core download"
    "core config --dbname=${db_name} --dbuser=${db_user} \
      --dbpass=${db_pass}"
    "core install --url='http://localhost:8080' \
      --title='Testing the LCP plugin' --admin_user=adminuser \
      --admin_password=adminpass --admin_email='admin@example.com'"
  )
  for install_cmd in "${wp_install[@]}"; do
    pwd
    echo $install_cmd | xargs ${wp_command}
    if [ $? -ne 0 ]; then
      echo "$install_cmd | xargs ${wp_command}"
      >&2 echo "Failed to install WordPress. The failed command was:"
      >&2 echo -e "\t${install_cmd}"
      exit 1
    fi
  done

  # Set up test data.
  sudo -u www-data wp plugin install wordpress-importer --activate
  sudo -u www-data wget ${test_data_url}
  test_data_success=true
  if [ $? -ne 0 ]; then
    >&2 echo "Unable to download test data. Proceeding..."
    test_data_success=false
  else
    sudo -u www-data wp import wptest.xml --authors=create
    rm wptest.xml
  fi

  # Use code from the repo
  ln -s /vagrant/ ${web_root}/wp-content/plugins/list-category-posts

  touch /var/log/wordpress
  if ${test_data_success}; then
    echo "Successfully set up WordPress."
  fi
fi

# Initalize the testing framework.
# http://wp-cli.org/docs/plugin-unit-tests/
if [ ! -f /var/log/phpunit ]; then
  echo "Initializing PHPUnit..."

  cd ${web_root}
  cd $(sudo -u www-data wp plugin path list-category-posts --dir)
  bash bin/install-wp-tests.sh wordpress_test root '' localhost latest
  if [ $? -ne 0 ]; then
    echo "Failed to initialize PHPUnit."
    exit 1
  fi
  chown -R ubuntu:www-data /tmp/wordpress/

  touch /var/log/phpunit
  echo "Successfully initialized PHPUnit."
fi
