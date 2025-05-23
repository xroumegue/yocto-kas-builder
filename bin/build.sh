#! /usr/bin/env bash

rootdir=$(dirname "$(realpath "$0")")
ip_addr=$(hostname -I | awk '{print $1}')

function fatal {
        echo "$1"
        usage
        exit 1
}

function usage {
cat << EOF
    $(basename "$0") [OPTIONS] CMD YAML_FILE
        --help, -h
            This help message
        --verbose, -v
            Show some verbose logs
        --kas_container
            kas-container executable path
        --force
            Force local.conf customization
        --update
            Update the git repositories
        --downloaddir
            Yocto Download directory
            Default to DOWNLOADDIR_DEFAULT if set, otherwise $(pwd)/downloads
        --sstatedir
            Yocto dstatedir directory
            Fallback to SSTATEDIR_DEFAULT if set, otherwise $(pwd)/sstate-cache
        --sstatedir_mirror
            Yocto sstate mirror directory
            Fallback to SSTATEDIR_MIRROR_DEFAULT if set, otherwise /srv/jenkins/sstate-cache
        --downloaddir_mirror
            Yocto download mirror directory
            Fallback to DOWNLOADDIR_MIRROR_DEFAULT if set, otherwise /srv/jenkins/downloads
        --hashserver
            Hash server host and server
            Default to "${ip_addr}:8686"
        --prserver
            PR server host and server
            Default to "${ip_addr}:8585"
        --ntpserver
            ntpserver to set in the NTP recipe
        --disable_connectivity_check
            disable connectivity check

    Possible commands:
        checkout
        dump
        build
        sdk
        deploy
        deploy-sdk
EOF
}


opts_short=vh
opts_long=verbose,help,update,force,kas_container:,sstatedir:,downloaddir:,sstatedir_mirror:,downloaddir_mirror:,hashserver:,prserver:,ntpserver:,disable_connectivity_check

options=$(getopt -o ${opts_short} -l ${opts_long} -- "$@" )

# shellcheck disable=SC2181
[ $? -eq 0 ] || {
    echo "Incorrect options provided"
    exit 1
}

eval set -- "$options"
while true; do
    case "$1" in
        --verbose | -v)
            verbose=true
            set -x
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        --force)
            force=true
            ;;
        --update)
            update=true
            ;;
        --kas_container)
            shift
            kas_container=$1
            ;;
        --downloaddir)
            shift
            downloaddir=$1
            ;;
        --sstatedir)
            shift
            sstatedir=$1
            ;;
        --sstatedir_mirror)
            shift
            sstatedir_mirror=$1
            ;;
        --downloaddir_mirror)
            shift
            downloaddir_mirror=$1
            ;;
        --hashserver)
            shift
            hashserver=$1
            ;;
        --prserver)
            shift
            prserver=$1
            ;;
        --ntpserver)
            shift
            ntpserver=$1
            ;;
        --disable_connectivity_check)
            disable_connectivity_check=true
            ;;
        --)
            shift
            break
            ;;
        *)
            ;;
    esac
    shift
done

if [ $# != 2 ];
then
        fatal "Not enough positional arguments"
fi

cmd="$1"
yaml_file="$2"

joinByChar() {
  local IFS="$1"
  shift
  echo "$*"
}

yaml_files=()
OLD_IFS=$IFS
IFS=':'
for file in ${yaml_file};
do
        yaml_files+=("${file}");
        [ -f "${file}" ] || fatal "${file} does not exist"
done 
shopt -s extglob
build_name=${yaml_files[0]}
build_name=${build_name%.*}
build_name=${build_name##*/}
build_name=${build_name//*(-poky)*(-kas)/}
shopt -u extglob

KAS_WORK_DIR=$(pwd)
KAS_BUILD_DIR="${KAS_WORK_DIR}/build-${build_name}"
export KAS_WORK_DIR
export KAS_BUILD_DIR

config_dir=$(dirname "$(realpath "${yaml_files[0]}")")
local_yaml="${config_dir}/.host-$(hostname).yaml"
yaml_files+=("${local_yaml}");
IFS=${OLD_IFS}

yaml_files_string=$(joinByChar ':' "${yaml_files[@]}")

verbose=${verbose:-false}
force=${force:-false}
update=${update:-false}
disable_connectivity_check=${disable_connectivity_check:-false}

kas_container_default=${KAS_CONTAINER:-kas-container}
kas_container=${kas_container:-${kas_container_default}}

downloaddir_default=${DOWNLOADDIR_DEFAULT:-$(pwd)/downloads}
sstatedir_default=${SSTATEDIR_DEFAULT:-$(pwd)/sstate-cache}
sstatedir_mirror_default=${SSTATEDIR_MIRROR_DEFAULT:-/srv/jenkins/sstate-cache}
downloaddir_mirror_default=${DOWNLOADDIR_MIRROR_DEFAULT:-/srv/jenkins/downloads}
hashserver_default="${ip_addr}:8686"
prserver_default="${ip_addr}:8585"
ntpserver_default=${NTPSERVER_DEFAULT:-pool.ntp.org}

sstatedir=${sstatedir:-${sstatedir_default}}
downloaddir=${downloaddir:-${downloaddir_default}}
sstatedir_mirror=${sstatedir_mirror:-${sstatedir_mirror_default}}
downloaddir_mirror=${downloaddir_mirror:-${downloaddir_mirror_default}}

hashserver=${hashserver:-${hashserver_default}}
prserver=${prserver:-${prserver_default}}
ntpserver=${ntpserver:-${ntpserver_default}}

builddir=${KAS_BUILD_DIR:-${rootdir}/build}
machine=genericarm64
image=core-image-weston
installdir=/srv/nfs/yocto/${machine}
sdkdir=/srv/sdk

cmd_args=()
kas_args=()
runtime_args=()

export KAS_CONTAINER_ENGINE=podman

if [ -z "${CI}" ];
then
cat > "${local_yaml}" <<EOF
header:
  version: 8

local_conf_header:
  mirror: |
    SSTATE_MIRRORS = "file://.* file:///sstate-mirrors/PATH"
    PREMIRRORS:prepend = "\\
      git://.*/.* file:///download-mirrors/ \\
      ftp://.*/.* file:///download-mirrors/ \\
      http://.*/.* file:///download-mirrors/ \\
      https://.*/.* file:///download-mirrors/ \\
    "
    BB_HASHSERVE = "${hashserver}"
    PRSERV_HOST = "${prserver}"
EOF
runtime_args+=("-v ${sstatedir_mirror}:/sstate-mirrors:ro")
runtime_args+=("-v ${downloaddir_mirror}:/download-mirrors:ro")
else
cat > "${local_yaml}" <<EOF
header:
  version: 8

local_conf_header:
  mirror: |
    BB_HASHSERVE = "${hashserver}"
    PRSERV_HOST = "${prserver}"
EOF
        export DL_DIR=${downloaddir:-downloaddir_default}
        export SSTATE_DIR=${sstatedir:-sstatedir_default}
fi

cat >> "${local_yaml}" <<EOF

  ntp_server: |
    CONF_NTP_SERVER = "${ntpserver}"
EOF

if [[ "${disable_connectivity_check}" == "true" ]]; then
cat >> "${local_yaml}" <<EOF

  sanity: |
    CONNECTIVITY_CHECK_URIS = ""
EOF
fi

if [[ "${update}" == "true" ]];then
  cmd_args+=("--update")
fi

if [[ "${verbose}" == "true" ]];then
  kas_args+=("-l")
  kas_args+=("debug")
fi

if [[ "${force}" == "true" ]];then
  cmd_args+=("--force-checkout")
fi

runtime_args+=("--network=host")

function do_kas_cmd {
       ${kas_container} \
                "${kas_args[@]}" \
                --ssh-dir "${HOME}"/.ssh \
                --runtime-args "${runtime_args[*]}" \
                  "$1" \
                  "${cmd_args[@]}" \
                  "${yaml_files_string}"
}

function do_deploy {
    echo "Deploying ${image}"
    rootfsimage=$(find "${builddir}/tmp/deploy/images/${machine}" -regextype posix-extended -regex ".*/${image}-${machine}\.rootfs\.tar\.(bz2|zst)")
    [ -e "${rootfsimage}" ] || fatal "root fs image not found"
    fstype=${rootfsimage##*.}
    echo "Deploying rootfsimage $rootfsimage (${fstype}) to ${installdir}"
    sudo --preserve-env bash -c "rm -Rf ${installdir}; mkdir -p ${installdir}; tar -C ${installdir}  --auto-compress -xf ${rootfsimage};"
}

function do_deploy_sdk {
    echo "Deploying SDK"

    sdkimage=$(find "${builddir}/tmp/deploy/sdk" -regextype posix-extended -regex ".*/.*-glibc-x86_64-${image}-armv8a-${machine}-toolchain-(.*)\.sh")
    [ -e "${sdkimage}" ] || fatal "sdk image not found"
    echo "Find sdimage $sdkimage"

    [[ "$sdkimage" =~ .*-glibc-x86_64-${image}-armv8a-${machine}-toolchain-(.*)\.sh ]]
    [ ${#BASH_REMATCH[@]} -eq 2 ] || fatal "Invalid sdkimage!"
    sdkversion=${BASH_REMATCH[1]}

    echo "Sdk ${sdkversion} image found: ${sdkimage}"

    sudo rm -Rf "${sdkdir}/${sdkversion}"
    sudo "${sdkimage}" -y -d "${sdkdir}/${sdkversion}"
}

case "$cmd" in
"build")
        do_kas_cmd build
;;
"dump")
        do_kas_cmd dump
;;
"checkout")
        do_kas_cmd checkout
;;
"shell")
        do_kas_cmd shell
;;
"sdk")
        cmd_args+=("-c populate_sdk")
        do_kas_cmd build
;;
"deploy")
        do_deploy
;;
"deploy-sdk")
        do_deploy_sdk
;;


esac

