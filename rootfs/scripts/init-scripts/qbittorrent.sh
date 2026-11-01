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
		log_warn "Removing stale $stale; previous shutdown was unclean."
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
		stop_container "Failed to set ${name}=${value} in ${qbt_config_path}"
	fi
}

# Check if qBittorrent.conf exists, if not, copy the template over
if [ ! -e $qbt_config_path ]; then
	log_warn "qBittorrent.conf is missing, this is normal for the first launch! Copying template."
	cp /defaults/qBittorrent.conf $qbt_config_path
	chmod 755 $qbt_config_path
	chown "${PUID}":"${PGID}" $qbt_config_path
fi

# SSL: self-signed certificate and key generated on first use, qBittorrent pointed at them via the verified helper.
# qBittorrent >= 5.1 reads these from [WebUI]; it migrates the legacy [Preferences] WebUI\* keys only once, so a key
# written there after the first start is ignored.
if [[ ${ENABLE_SSL,,} == 'yes' ]]; then
	log_info "ENABLE_SSL is set to ${ENABLE_SSL}. The container will handle SSL."
	ssl_cert="/config/qBittorrent/config/WebUICertificate.crt"
	ssl_key="/config/qBittorrent/config/WebUIKey.key"
	if [[ ! -e "$ssl_cert" || ! -e "$ssl_key" ]]; then
		log_warn "WebUI certificate or key is missing, generating a new self-signed certificate and key"
		openssl req -new -x509 -nodes -out "$ssl_cert" -keyout "$ssl_key" -subj "/C=NL/ST=localhost/L=localhost/O=/OU=/CN="
		chown "${PUID}":"${PGID}" "$ssl_cert" "$ssl_key"
	fi
	qbt_set_setting WebUI 'HTTPS\CertificatePath' "$ssl_cert"
	qbt_set_setting WebUI 'HTTPS\KeyPath' "$ssl_key"
	qbt_set_setting WebUI 'HTTPS\Enabled' true
fi

# Set the umask
if [[ -n "${UMASK}" ]]; then
	log_info "UMASK defined as '${UMASK}'"
	UMASK=$(echo "${UMASK}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
	export UMASK
else
	log_warn "UMASK not defined (via -e UMASK), defaulting to '002'"
	export UMASK="002"
fi

# Set WebUI password
if [[ -n "${WEBUI_PASSWORD}" ]] && ! grep -Exq 'WebUI\\Password_PBKDF2=.+' "$qbt_config_path"; then
	log_info "Setting WebUI password to WEBUI_PASSWORD"
	salt="$(dd if=/dev/urandom bs=16 count=1 status=none | base64)"
	key="$(printf '%s' "$WEBUI_PASSWORD" | /scripts/helper/dwk "$salt" | tail -n 1)"
	qbt_set_setting Preferences 'WebUI\Password_PBKDF2' "\"@ByteArray($salt:$key)\""
elif ! grep -Exq 'WebUI\\Password_PBKDF2=.+' "$qbt_config_path"; then
	log_info "WebUI password not set. To access the WebUI set a password or get a temporary password from the qBittorrent logs."
fi

# VPN interface binding
if [[ ${VPN_ENABLED,,} != 'no' ]]; then
	log_debug "Setting qBt bind interface to \"${VPN_DEVICE_TYPE}\""
	qbt_set_setting BitTorrent 'Session\Interface' "${VPN_DEVICE_TYPE}"
	qbt_set_setting BitTorrent 'Session\InterfaceName' "${VPN_DEVICE_TYPE}"
fi

##########
# Save environment variables

export_contenv UMASK
