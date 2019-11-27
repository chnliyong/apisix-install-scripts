#!/bin/bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -o errtrace
set -o errexit
set -o pipefail
set -o xtrace

LUAROCKS_VERSION="3.2.1"
LUAROCKS_BIN=

APISIX_VERSION="0.9-incubating"

install_initialize() {
    APISIX_SRC_BASE_URL=(https://dist.apache.org/repos/dist/release/incubator/apisix)
    LUAROCKS_TARBALL=(http://luarocks.org/releases/luarocks-${LUAROCKS_VERSION}.tar.gz)
  
    local bash_min_version="3.2.25"
    if
        [[ -n "${BASH_VERSION:-}" &&
            "$(\printf "%b" "${BASH_VERSION:-}\n${bash_min_version}\n" | LC_ALL=C \sort -t"." -k1,1n -k2,2n -k3,3n | \head -n1)" != "${bash_min_version}"
        ]]; then
        echo "bash ${bash_min_version} required (you have $BASH_VERSION)"
        exit 1
    fi
  
    export HOME PS4
  
    PS4="+ \${BASH_SOURCE##\${rvm_path:-}} : \${FUNCNAME[0]:+\${FUNCNAME[0]}()}  \${LINENO} > "

    command -v grep >/dev/null 2>&1 || fail "Could not find 'grep' command, make sure it's available first before continuing installation."
    command -v sort >/dev/null 2>&1 || fail "Could not find 'sort' command, make sure it's available first before continuing installation."
    command -v cut >/dev/null 2>&1 || fail "Could not find 'cut' command, make sure it's available first before continuing installation."
}

install_initialize

log()  { printf "%b\n" "$*"; }
debug(){ [[ ${rvm_debug_flag:-0} -eq 0 ]] || printf "%b\n" "$*" >&2; }
warn() { log "WARN: $*" >&2 ; }
fail() { fail_with_code 1 "$*" ; }
fail_with_code() { code="$1" ; shift ; log "\nERROR: $*\n" >&2 ; exit "$code" ; }

get_distro_info() {
    OS_NAME=$(uname)
    case "$OS_NAME" in
        Linux)
            if [ -f /etc/os-release ]; then
                OS_DISTRO_ID=$(cat /etc/os-release | grep '^ID=' | cut -d'=' -f2)
                OS_DISTRO_VERSION=$(cat /etc/os-release | grep '^VERSION_ID=' | cut -d'=' -f 2)
            else
                OS_DISTRO_ID=unknown
                OS_DISTRO_VERSION=unknown
            fi
            ;;
        Darwin)
            ;;
        *)
            fail "This script currently only support Linux and MacOS"

    esac
}

# ref https://openresty.org/en/linux-packages.html
install_openresty_for_ubuntu() {
    local ubuntu_min_version="14.04"
    if [[ -n "$OS_DISTRO_VERSION" &&
            "$(\printf "%b" "${OS_DISTRO_VERSION:-}\n${ubuntu_min_version}\n" | LC_ALL=C \sort -t"." -k1,1n -k2,2n | \head -n1)" != "${OS_DISTRO_VERSION}"
        ]]; then
        fail "Only Ubuntu $ubuntu_min_version or later supported, you have Ubuntu $ubuntu_min_version"
    fi

    # update metadata cache
    sudo apt-get update

    # install some prerequisites needed by adding GPG public keys (could be removed later)
    sudo apt-get -y install --no-install-recommends wget gnupg ca-certificates 
    
    # import our GPG key:
    curl -L https://openresty.org/package/pubkey.gpg | sudo apt-key add - 
    
    # for installing the add-apt-repository command
    # (you can remove this package and its dependencies later):
    sudo apt-get -y install --no-install-recommends software-properties-common

    # add the our official APT repository:
    sudo add-apt-repository -y "deb http://openresty.org/package/ubuntu $(lsb_release -sc) main"

    # to update the APT index:
    sudo apt-get update
    sudo apt-get -y install openresty

    # We don't use the default OpenResty service
    sudo systemctl disable openresty.service
    sudo systemctl stop openresty.service
}

install_openresty_for_centos() {
    sudo yum makecache

    sudo yum install yum-utils
    sudo yum-config-manager --add-repo https://openresty.org/package/centos/openresty.repo

    sudo yum install openresty openresty-resty

    # We don't use the default OpenResty service
    sudo systemctl disable openresty.service
    sudo systemctl stop openresty.service
}

ensure_openresty() {
    local openresty=$(command -v openresty)
    if [ -n "$openresty" ]; then
        local openresty_min_version="1.15.8.1"

        # The output of command `openresty -v` is like: nginx version: openresty/1.15.8.2
        local openresty_version=$(openresty -v 2>&1 | cut -d'/' -f2)

        if [ -z "$openresty_version" ]; then
            fail "Cannot get openresty version, please check!"
        fi

        if [[ "$(\printf "%b" "${openresty_version}\n${openresty_min_version}\n" | LC_ALL=C \sort -t"." -k1,1n -k2,2n -k3,3n -k4,4n | \head -n1)" != "${openresty_min_version}" ]]; then
            fail "OpenResty ${openresty_min_version} required (you have $openresty_version)"
        fi
    else
        if [ "$OS_NAME" = Linux ]; then
            case "$OS_DISTRO_ID" in
                ubuntu)
                    install_openresty_for_ubuntu
                    ;;
                centos)
                    install_openresty_for_centos
                    ;;
                debian)
                    ;;
                *)
                    ;;
            esac
        elif [ "$OS_NAME" = Darwin ]; then
            fail "Not Implemented!"
        else
            fail "Cannot reach here, bug occured!"
        fi
    fi
    LUA_JIT_DIR=$(openresty -V 2>&1 | grep -Eo -e '--prefix=(.*?)/nginx' | sed -e 's@--prefix=@@' -e 's@nginx@luajit@')
}

install_luarocks() {
    local prefix=/usr/local
    [ -e /tmp/luarocks-${LUAROCKS_VERSION}.tar.gz ] && rm -rf /tmp/luarocks-${LUAROCKS_VERSION}*
    cd /tmp && curl -LO "$LUAROCKS_TARBALL" \
        && tar -xf luarocks-${LUAROCKS_VERSION}.tar.gz
    cd luarocks-${LUAROCKS_VERSION} \
        && ./configure --with-lua=${LUA_JIT_DIR} --prefix=$prefix \
        && make \
        && make install
    LUAROCKS_BIN=$prefix/bin/luarocks
}

install_apisix() {
    local apisix_home=/usr/local/apisix
    local numeric_version=$(echo $APISIX_VERSION | cut -d'-' -f1)
    local tarball=apache-apisix-${APISIX_VERSION}-src.tar.gz
    local src_url=${APISIX_SRC_BASE_URL}/${numeric_version}/${tarball}

    [ -e /tmp/${tarball} ] && rm -rf /tmp/apache-apisix*
    cd /tmp && curl -LO "$src_url"

    local untar_dir=$(tar -tf $tarball | head -n1 | cut -d'/' -f1)
    tar -xf $tarball
    cd $untar_dir
    local rockspec=$(ls rockspec | grep -E "apisix-${numeric_version}.*\\.rockspec" | tail -n1)
    rm -rf $apisix_home && mkdir -p $apisix_home
    luarocks install --lua-dir="${LUA_JIT_DIR}" "rockspec/$rockspec" --tree=/usr/local/apisix/deps --only-deps --local
    cp -R conf $apisix_home/
    cp -R lua $apisix_home/
    cp -R bin $apisix_home/

    sed -i "1c\#\!/usr/bin/env ${LUA_JIT_DIR}/bin/luajit" ${apisix_home}/bin/apisix
    rm -f /usr/bin/apisix && ln -s ${apisix_home}/bin/apisix /usr/bin/apisix
}

ensure_luarocks3() {
    local luarocks=$(command -v luarocks)
    if [ -z "$luarocks" ]; then
        install_luarocks
    else
        local luarocks_version=$($luarocks --version | head -n1 | awk '{print $NF}')
        local luarocks_min_version="3.0.0"
        if [[ "$(\printf "%b" "${luarocks_version}\n${luarocks_min_version}\n" | LC_ALL=C \sort -t"." -k1,1n -k2,2n -k3,3n | \head -n1)" != "${luarocks_min_version}" ]]; then
            warn "LuaRocks ${luarocks_min_version} required (you have $luarocks_version)"
            info "Try to install LuaRocks $LUAROCKS_VERSION ..."
            install_luarocks
        else
            LUAROCKS_BIN=$luarocks
        fi
    fi
}

install_deps() {
    get_distro_info
    ensure_openresty
    ensure_luarocks3
}

install() {
    install_deps
    install_apisix
}

install
# vim: set sts=4 sw=4 et ai si :
