#!/bin/sh

# Updates the Angular app configuration file with the provided environment variables.

BASE_HREF=${BASE_HREF:-"/"}
INDEX_FILE="/usr/share/nginx/html/index.html"
OCTAVE_API_URL=${OCTAVE_API_URL:-"http://localhost:5100"}
CONFIG_FILE="/usr/share/nginx/html/assets/configurations/config.production.json"
ENABLE_AUTH=${ENABLE_AUTH:-"true"}

# Set base href
if [ -f "$INDEX_FILE" ]; then
  echo "Setting the <base href> in Angular's index.html to $BASE_HREF"
  sed -i "s|<base href=\"/\">|<base href=\"$BASE_HREF\">|" "$INDEX_FILE"
else
  echo "Index file $INDEX_FILE not found!"
  exit 1
fi

# Set Octave API URL & enableAuth
if [ -f "$CONFIG_FILE" ]; then
  echo "Setting the octave-api property in Angular's config.production.json to $OCTAVE_API_URL"
  sed -i "s|\"octave-api\": *\"[^\"]*\"|\"octave-api\": \"$OCTAVE_API_URL\"|" "$CONFIG_FILE"

  # Set the "enableAuth property based on the ENABLE_AUTH environment variable, favoring true.
  if [ "$ENABLE_AUTH" = "false" ]; then
    echo "Setting the enableAuth property in Angular's config.production.json to false"
    sed -i 's|\("enableAuth": *\).*|\1false|' "$CONFIG_FILE"
  else
    echo "Setting the enableAuth property in Angular's config.production.json to true"
    sed -i 's|\("enableAuth": *\).*|\1true|' "$CONFIG_FILE"
  fi
else
  echo "Config file $CONFIG_FILE not found!"
  exit 1
fi

# Start Nginx
exec nginx -g "daemon off;"