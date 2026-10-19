#!/bin/sh
# Publish the built packages in dist/ as a GitHub release:
#   tag vX.Y.Z           -> release vX.Y.Z (tag must match PKG_VERSION)
#   manual run (Actions) -> release vPKG_VERSION from the chosen branch, tag created
#   default branch push  -> pre-release "dev", replaced on every push
set -e

ver=$(sed -n 's/^PKG_VERSION:=//p' Makefile)

if [ "$GITHUB_REF_TYPE" = tag ] || [ "$GITHUB_EVENT_NAME" = workflow_dispatch ]; then
	if [ "$GITHUB_REF_TYPE" = tag ]; then
		tag=$GITHUB_REF_NAME
		target=''
	else
		tag=v$ver
		target=$GITHUB_SHA
	fi
	if [ "$tag" != "v$ver" ]; then
		echo "::error::tag $tag does not match PKG_VERSION $ver in Makefile"
		exit 1
	fi
	if gh release view "$tag" > /dev/null 2>&1; then
		gh release upload "$tag" dist/* --clobber
	elif [ -n "$target" ]; then
		gh release create "$tag" dist/* --target "$target" --title "$tag" --notes ''
	else
		gh release create "$tag" dist/* --verify-tag --title "$tag" --notes ''
	fi
	header="Пакеты для OpenWrt 24.10 (opkg) и 25.12 (apk)."
	changes=$(gh api "repos/$GITHUB_REPOSITORY/releases/generate-notes" -f tag_name="$tag" --jq .body || true)
else
	tag=dev
	sha=$(echo "$GITHUB_SHA" | cut -c1-7)
	gh release delete dev --yes --cleanup-tag 2> /dev/null || true
	gh release create dev dist/* --prerelease --target "$GITHUB_SHA" --title "Dev build $sha" --notes ''
	header="Свежая сборка из ветки \`$GITHUB_REF_NAME\` (коммит $sha), обновляется при каждом пуше.
Стабильные версии — в релизах \`vX.Y.Z\`."
	changes=''
fi

asset() { # name prefix, extension -> download url
	gh release view "$tag" --json assets \
		--jq ".assets[] | select((.name | startswith(\"$1\")) and (.name | endswith(\"$2\"))) | .url" | head -n1
}

app_ipk=$(asset luci-app- .ipk)
ru_ipk=$(asset luci-i18n- .ipk)
app_apk=$(asset luci-app- .apk)
ru_apk=$(asset luci-i18n- .apk)

cat > notes.md <<EOF
$header

## Установка

Команды выполняются на роутере по SSH.

**OpenWrt 24.10 — opkg, \`.ipk\`**

\`\`\`sh
cd /tmp
wget -O yandex-speedtest.ipk "$app_ipk"
wget -O yandex-speedtest-ru.ipk "$ru_ipk"
opkg update
opkg install yandex-speedtest.ipk yandex-speedtest-ru.ipk
rm -rf /tmp/luci-*; /etc/init.d/rpcd restart
\`\`\`

**OpenWrt 25.12 — apk, \`.apk\`** (пакеты без подписи)

\`\`\`sh
cd /tmp
wget -O yandex-speedtest.apk "$app_apk"
wget -O yandex-speedtest-ru.apk "$ru_apk"
apk update
apk add --allow-untrusted ./yandex-speedtest.apk ./yandex-speedtest-ru.apk
rm -rf /tmp/luci-*; /etc/init.d/rpcd restart
\`\`\`

Карточка теста появится на странице **Состояние → Обзор**, настройки — в **Службы → Тест скорости Яндекса**.
EOF

if [ -n "$changes" ]; then
	printf '\n%s\n' "$changes" >> notes.md
fi

gh release edit "$tag" --notes-file notes.md
