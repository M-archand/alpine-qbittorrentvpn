#!/bin/bash

# shellcheck disable=SC1091
source /scripts/helper/functions.sh
# Create /config/qBittorrent (if it doesn't exist)
mkdir -p /config/qBittorrent/config

# Set the rights on the /config/qBittorrent
chown -R "${PUID}":"${PGID}" /config/qBittorrent

# Remove stale lock/socket files from an unclean shutdown; qBittorrent >= 5.2
# refuses to start while they exist.
for stale in \
	"/config/qBittorrent/config/lockfile" \
	"/config/qBittorrent/config/ipc-socket" \
	"/config/qBittorrent/data/lockfile" \
	"/config/qBittorrent/data/ipc-socket"; do
	if [ -e "$stale" ]; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] Removing stale $stale; previous shutdown was unclean."
		rm -f "$stale"
	fi
done

# Set the rights on the /downloads folder
if [[ $DOWNLOAD_DIR_CHOWN != "no" ]]; then
	chown -R "${PUID}":"${PGID}" /downloads
fi

qbt_config_path="/config/qBittorrent/config/qBittorrent.conf"

# Set key=value in [section] of qBittorrent.conf (replace or add, create section if missing) and verify by read-back
qbt_set_setting() {
	local section="$1" name="$2" value="$3" updated
	updated="$(QBT_SECTION="$section" QBT_NAME="$name" QBT_VALUE="$value" awk '
		BEGIN {
			header = "[" ENVIRON["QBT_SECTION"] "]"
			prefix = ENVIRON["QBT_NAME"] "="
			line = prefix ENVIRON["QBT_VALUE"]
			in_section = 0
			done = 0
		}
		/^\[/ {
			# Leaving the target section without having seen the key: add it here
			if (in_section && !done) { print line; done = 1 }
			in_section = ($0 == header)
			print
			next
		}
		in_section && index($0, prefix) == 1 {
			# Replace the first occurrence, drop duplicates
			if (!done) { print line; done = 1 }
			next
		}
		{ print }
		END {
			if (!done) {
				if (!in_section) { print ""; print header }
				print line
			}
		}
	' "$qbt_config_path")"
	printf '%s\n' "$updated" > "$qbt_config_path"

	if ! grep -Fxq "${name}=${value}" "$qbt_config_path"; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] Failed to set ${name}=${value} in ${qbt_config_path}"
		stop_container
	fi
}

# Check if qBittorrent.conf exists, if not, copy the template over
if [ ! -e $qbt_config_path ]; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] qBittorrent.conf is missing, this is normal for the first launch! Copying template."
	cp /defaults/qBittorrent.conf $qbt_config_path
	chmod 755 $qbt_config_path
	chown "${PUID}":"${PGID}" $qbt_config_path
fi

# The mess down here checks if SSL is enabled.
if [[ ${ENABLE_SSL,,} == 'yes' ]]; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] ENABLE_SSL is set to ${ENABLE_SSL}. The container will handle SSL."
	if [ ! -e /config/qBittorrent/config/WebUICertificate.crt ]; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] WebUI Certificate is missing, generating a new Certificate and Key"
		openssl req -new -x509 -nodes -out /config/qBittorrent/config/WebUICertificate.crt -keyout /config/qBittorrent/config/WebUIKey.key -subj "/C=NL/ST=localhost/L=localhost/O=/OU=/CN="
		chown -R "${PUID}":"${PGID}" /config/qBittorrent/config
	elif [ ! -e /config/qBittorrent/config/WebUIKey.key ]; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] WebUI Key is missing, generating a new Certificate and Key"
		openssl req -new -x509 -nodes -out /config/qBittorrent/config/WebUICertificate.crt -keyout /config/qBittorrent/config/WebUIKey.key -subj "/C=NL/ST=localhost/L=localhost/O=/OU=/CN="
		chown -R "${PUID}":"${PGID}" /config/qBittorrent/config
	fi
	if grep -Fxq 'WebUI\HTTPS\CertificatePath=/config/qBittorrent/config/WebUICertificate.crt' "$qbt_config_path"; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $qbt_config_path already has the line WebUICertificate.crt loaded, nothing to do."
	else
		echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $qbt_config_path doesn't have the WebUICertificate.crt loaded. Added it to the config."
		echo 'WebUI\HTTPS\CertificatePath=/config/qBittorrent/config/WebUICertificate.crt' >> "$qbt_config_path"
	fi
	if grep -Fxq 'WebUI\HTTPS\KeyPath=/config/qBittorrent/config/WebUIKey.key' "$qbt_config_path"; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $qbt_config_path already has the line WebUIKey.key loaded, nothing to do."
	else
		echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $qbt_config_path doesn't have the WebUIKey.key loaded. Added it to the config."
		echo 'WebUI\HTTPS\KeyPath=/config/qBittorrent/config/WebUIKey.key' >> "$qbt_config_path"
	fi
	if grep -xq 'WebUI\\HTTPS\\Enabled=true\|WebUI\\HTTPS\\Enabled=false' "$qbt_config_path"; then
		if grep -xq 'WebUI\\HTTPS\\Enabled=false' "$qbt_config_path"; then
			echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $qbt_config_path does have the WebUI\HTTPS\Enabled set to false, changing it to true."
			sed -i 's/WebUI\\HTTPS\\Enabled=false/WebUI\\HTTPS\\Enabled=true/g' "$qbt_config_path"
		else
			echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $qbt_config_path does have the WebUI\HTTPS\Enabled already set to true."
		fi
	else
		echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $qbt_config_path doesn't have the WebUI\HTTPS\Enabled loaded. Added it to the config."
		echo 'WebUI\HTTPS\Enabled=true' >> "$qbt_config_path"
	fi
fi

# Set the umask
if [[ -n "${UMASK}" ]]; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] UMASK defined as '${UMASK}'"
	UMASK=$(echo "${UMASK}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
	export UMASK
else
	echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] UMASK not defined (via -e UMASK), defaulting to '002'"
	export UMASK="002"
fi

# Set WebUI password
if [[ -n "${WEBUI_PASSWORD}" ]] && ! grep -Exq 'WebUI\\Password_PBKDF2=.+' "$qbt_config_path"; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Setting WebUI password to WEBUI_PASSWORD"
	salt="$(dd if=/dev/urandom bs=16 count=1 status=none | base64)"
	key="$(/scripts/helper/dwk "$WEBUI_PASSWORD" "$salt" | head -2 | tail -1)"
	qbt_set_setting Preferences 'WebUI\Password_PBKDF2' "\"@ByteArray($salt:$key)\""
elif ! grep -Exq 'WebUI\\Password_PBKDF2=.+' "$qbt_config_path"; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] WebUI password not set. To access the WebUI set a password or get a temporary password from the qBittorrent logs."
fi

# VPN interface binding
if [[ ${VPN_ENABLED,,} != 'no' ]]; then
	if [[ "$DEBUG" == "yes" ]]; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] Setting qBt bind interface to \"${VPN_DEVICE_TYPE}\""
	fi
	qbt_set_setting BitTorrent 'Session\Interface' "${VPN_DEVICE_TYPE}"
	qbt_set_setting BitTorrent 'Session\InterfaceName' "${VPN_DEVICE_TYPE}"
fi

##########
# Save envirnonment variables

CONT_INIT_ENV="/var/run/s6/container_environment"
mkdir -p $CONT_INIT_ENV
export_vars=("UMASK")

for name in "${export_vars[@]}"; do
	echo -n "${!name}" > "$CONT_INIT_ENV/$name"
done
