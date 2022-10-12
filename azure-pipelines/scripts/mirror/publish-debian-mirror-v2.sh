#!/bin/bash -e

####################################################################
# Publish the debian mirror by aptly
# 1. Publish gpg public keys in the mirror
# 2. Publish the mirror snapshot
# 3. Publish the full mirror contains the history packages
####################################################################

usage()
{
    echo "Usage:  $0 -n <name> -p <publish_root> -u <url> -d <distributions> -a <architectures> -c <components> [-b <backup_storage> [ -s <storage_suffix>]] [-f]"
    echo "Example: $0 -n bullseye \\"
    echo "         -u \"http://deb.debian.org/debian\" -d bullseye,bullseye-updates,bullseye-backports \\"
    echo "         -a amd64,armhf,arm64 -c contrib,non-free,main \\"
    echo "         -b sonicstoragepublic0"
    exit 1
}

MIRROR_NAME=
PUBLISH_ROOT=
MIRROR_DISTRIBUTIONS=
MIRROR_URL=
MIRROR_ARICHTECTURES=
MIRROR_COMPONENTS=
BACKUP_STORAGE=
STORAGE_SUFFIX="core.windows.net"
FORCE=
CLIENT_ID=

while getopts "n:p:u:d:a:c:b:i:f" opt; do
    case $opt in
        n)
            MIRROR_NAME=$OPTARG
            ;;
        p)
            PUBLISH_ROOT=$OPTARG
            ;;
        u)
            MIRROR_URL=$OPTARG
            ;;
        d)
            MIRROR_DISTRIBUTIONS=$OPTARG
            ;;
        a)
            MIRROR_ARICHTECTURES=$OPTARG
            ;;
        c)
            MIRROR_COMPONENTS=$OPTARG
            ;;
        b)
            BACKUP_STORAGE=$OPTARG
            ;;
        s)
            STORAGE_SUFFIX=$OPTARG
            ;;
        f)
            FORCE=$OPTARG
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "$MIRROR_FILESYSTEM" ]; then
    echo "MIRROR_FILESYSTEM not set" 1>&2
    exit 1
fi

if [ -z "$MIRROR_NAME" ] || [ -z "$MIRROR_DISTRIBUTIONS" ] || [ -z "$MIRROR_URL" ] || 
   [ -z "$MIRROR_ARICHTECTURES" ] || [ -z "$MIRROR_COMPONENTS" ]; then
    echo "Some required options not set, see usage as below:" 1>&2
    usage
fi


# Persisted NFS:
# /nfs/v1/aptly/fs/debian/work/pool
# /nfs/v1/aptly/fs/debian/work/db -> /mirrors/v1/aptly/fs/debian/work/db
# /nfs/v1/aptly/fs/debian/work/dbs/bullseye
# /nfs/v1/aptly/publish/debian/dists/bullseye
# /nfs/v1/aptly/publish/debian/pool
# /nfs/v1/aptly/release

# Dynamic disk:
# /mirrors/v1/aptly/fs/debian/work

[ -z "$NFS_ROOT" ] && NFS_ROOT=/nfs
[ -z "$MIRROR_ROOT" ] && MIRROR_ROOT=/mirrors
MIRROR_REL_DIR=v1/aptly
NFS_REL_DIR=$NFS_ROOT/$MIRROR_REL_DIR
NFS_PUBLISH_DIR=$NFS_REL_DIR/publish
NFS_WORK_DIR=$NFS_REL_DIR/fs/$MIRROR_FILESYSTEM/work
NFS_DBS_DIR=$NFS_WORK_DIR/dbs/$MIRROR_NAME

WORK_DIR=$MIRROR_ROOT/$MIRROR_REL_DIR/fs/$MIRROR_FILESYSTEM/work

SOURCE_DIR=$(pwd)
SAVE_WORKSPACE=n
APTLY_CONFIG=aptly-debian.conf
PACKAGES_DENY_LIST=debian-packages-denylist.conf
ENCRIPTED_KEY_GPG=./encrypted_private_key.gpg
export GNUPGHOME=gnupg
GPG_FILE=$GNUPGHOME/mykey.gpg

BACKUP_STORAGE_URL="https://$BACKUP_STORAGE.blob.$STORAGE_SUFFIX"
STORAGE_MIRROR_URL="$BACKUP_STORAGE_URL$MIRROR_ROOT/$MIRROR_REL_DIR/$MIRROR_FILESYSTEM"
HAS_PUBLISH_UPDATE=n


FILESYSTEM="filesystem:common:"


sudo rm -rf $WORK_DIR
mkdir -p $WORK_DIR
cd $WORK_DIR

validate_input_variables()
{
    if [ -z "$GPG_KEY" ]; then
        echo "The encrypted gpg key is not set." 1>&2
        exit 1
    fi

    if [ -z "$PASSPHRASE" ]; then
        echo "The passphrase is not set." 1>&2
        exit 1
    fi
}

prepare_workspace()
{
    echo "pwd=$(pwd)"
    mkdir -p $NFS_WORK_DIR/pool
    mkdir -p $NFS_PUBLISH_DIR
    ln -nsf $WORK_DIR/db $NFS_WORK_DIR/db
    sed -e "s#PUBLISHDIR_PLACEHOLDER#$NFS_PUBLISH_DIR/$MIRROR_FILESYSTEM#" \
        -e "s#ROOTDIR_PLACEHOLDER#$NFS_WORK_DIR#" \
       $SOURCE_DIR/azure-pipelines/config/aptly-debian-v2.conf > $APTLY_CONFIG
    cp $SOURCE_DIR/azure-pipelines/config/debian-packages-denylist.conf $PACKAGES_DENY_LIST

    # Import gpg key
    rm -rf $GNUPGHOME
    mkdir $GNUPGHOME
    echo "pinentry-mode loopback" > $GNUPGHOME/gpg.conf
    echo "$GPG_KEY" > $ENCRIPTED_KEY_GPG
    chmod 600 $GNUPGHOME/*
    chmod 700 $GNUPGHOME
    gpg --no-default-keyring --passphrase="$PASSPHRASE" --keyring=$GPG_FILE --import "$ENCRIPTED_KEY_GPG"

    sudo rm -rf db
    mkdir -p db

    if [ "$CREATE_DB"  == y ]; then
        return
    fi

    local latest_db=$NFS_DBS_DIR/latest.tar.gz
    if [ ! -f "$latest_db" ]; then
        echo "The databse backup file $latest_db does not exist, please restore the file, add CREATE_DB=y option or recreat it." 1>&2
        exit 1
    fi

    tar -xzvf "$latest_db" -C .
}

save_workspace()
{
    set -x
    local release_dir=$NFS_REL_DIR/release
    local package="db-$(date +%Y%m%d%H%M%S).tar.gz"
    local public_key_file_asc=$NFS_PUBLISH_DIR/public_key.asc
    local public_key_file_gpg=$NFS_PUBLISH_DIR/public_key.gpg

    if [ "$SAVE_WORKSPACE" == "n" ]; then
        return
    fi

    gpg --no-default-keyring --keyring=$GPG_FILE --export -a > "$public_key_file_asc"
    gpg --no-default-keyring --keyring=$GPG_FILE --export > "$public_key_file_gpg"
    mkdir -p $release_dir
    cp "$public_key_file_asc" "$public_key_file_gpg" $release_dir/

    if [ -z "$BACKUP_STORAGE" ]; then
        echo "The back storage not set"
        return
    fi

    echo "Backup the aptly pool"
    exclude_pattern=$(sed '/^[[:space:]]*$/d' $PACKAGES_DENY_LIST | sed 's/$/*/' | paste -sd ";" -)
    echo "exclude_pattern=$exclude_pattern"
    azcopy sync "$NFS_WORK_DIR/pool/" "$STORAGE_MIRROR_URL/pool/" --exclude-pattern="$exclude_pattern" --recursive=true

    echo "Backup the aptly database"
    tar -czvf "$package" db
    echo $package > latest
    azcopy cp ./$package "$STORAGE_MIRROR_URL/work/$MIRROR_NAME/dbs/"
    azcopy cp ./latest "$STORAGE_MIRROR_URL/work/$MIRROR_NAME/dbs/"
    rm -f $NFS_DBS_DIR/prev.tar.gz
    mv -f $NFS_DBS_DIR/latest.tar.gz $NFS_DBS_DIR/prev.tar.gz 2>/dev/null || true
    mkdir -p $NFS_DBS_DIR/
    cp ./$package "$NFS_DBS_DIR/latest.tar.gz"

    echo "Release the mirror"
    local tmp_dir=$NFS_WORK_DIR/tmp/$MIRROR_NAME
    mkdir -p $release_dir/$MIRROR_FILESYSTEM/dists
    ln -nfs ../../publish/$MIRROR_FILESYSTEM/pool $release_dir/$MIRROR_FILESYSTEM/pool
    mkdir -p $tmp_dir
    for dist in $(echo $MIRROR_DISTRIBUTIONS | tr ',' ' '); do
      echo "Publishing i$MIRROR_FILESYSTEM/$MIRROR_NAME/$dist..."
      sudo rm -rf $tmp_dir/$dist
      cp -a $NFS_PUBLISH_DIR/$MIRROR_FILESYSTEM/dists/$dist $tmp_dir/$dist

      # Swap the distribution, make sure the release folder very short down time
      sudo rm -rf $tmp_dir/last-$dist
      local releas_dist=$release_dir/$MIRROR_FILESYSTEM/dists/$dist
      [ -d $releas_dist ] && mv -f $releas_dist $tmp_dir/last-$dist
      mv -f $tmp_dir/$dist $releas_dist
      rm -rf $tmp_dir/last-$dist
    done
 
    echo "Saving workspace to $package is complete"
}

get_repo_name()
{
    local name=$1
    local dist=$2
    local component=$3
    local distname=$(echo $dist | tr '/' '_')
    echo "repo-${name}-${distname}-${component}" 
}

update_repos()
{
    local name=$1
    local url=$2
    local dist=$3
    local archs=$4
    local components=$5
    local distname=$(echo $dist | tr '/' '_')

    # Create the aptly mirrors if it does not exist
    local repos=
    local need_to_publish=n
    [ "$CREATE_DB" == "y" ] && need_to_publish=y
    for component in $(echo $components | tr ',' ' '); do
        local mirror="mirror-${name}-${distname}-${component}"
        local repo=$(get_repo_name $name $distname $component)
        local logfile="${mirror}.log"

        # Create the aptly mirror if not existing
        if ! aptly -config $APTLY_CONFIG mirror show $mirror > /dev/null 2>&1; then
            WITH_SOURCES="-with-sources"
            [ "$dist" == "jessie" ] && WITH_SOURCES=""
            aptly -config $APTLY_CONFIG -ignore-signatures -architectures="$archs" mirror create -force-components $WITH_SOURCES $mirror $url $dist $component
            SAVE_WORKSPACE=y
        fi

        # Remove the packages in the deny list
        if aptly -config $APTLY_CONFIG repo show $repo > /dev/null 2>&1; then
            while IFS= read -r line
            do
                # trim the line
                local filter=$(echo $line | awk '{$1=$1};1')
                if [ -z "filter" ]; then
                    continue
                fi

                aptly -config $APTLY_CONFIG repo remove $repo $filter
           done < $PACKAGES_DENY_LIST
        fi

        repos="$repos $repo"
        
        local success=n
        local has_error=n
        local retry=5
        # Update the aptly mirror with retry
        set -o pipefail
        for ((i=1;i<=$retry;i++)); do
            echo "Try to update the mirror, retry step $i of $retry"
            if aptly -config $APTLY_CONFIG -ignore-signatures mirror update -max-tries=5 $mirror | tee $logfile; then
                echo "Successfully update the mirror $mirror"
                success=y
                break
            else
                echo "Failed to update the mirror $mirror, sleep 10 seconds"
                sleep 10
                has_error=y
            fi
        done

        if [ "$success" != "y" ] && [ "$mirror" == "mirror-jessie-security-jessie_updates-main" ]; then
            aptly -config $APTLY_CONFIG mirror edit -with-sources=false -ignore-signatures  -archive-url='https://packages.trafficmanager.net/debian/debian-security' $mirror
            if aptly -config $APTLY_CONFIG -ignore-signatures mirror update -max-tries=5 $mirror | tee $logfile; then
                echo "Successfully update the mirror $mirror"
            fi
            aptly -config $APTLY_CONFIG mirror edit -with-sources=false -ignore-signatures  -archive-url="$url" $mirror
            if aptly -config $APTLY_CONFIG -ignore-signatures mirror update -max-tries=5 $mirror | tee $logfile; then
                echo "Successfully update the mirror $mirror"
                success=y
            fi
        fi

        set +o pipefail
        if [ "$success" != "y" ]; then
            echo "Failed to update the mirror $mirror" 1>&2
            exit 1
        fi

        # Create the aptly repo if not existing
        if ! aptly -config $APTLY_CONFIG repo show $repo > /dev/null 2>&1; then
            aptly -config $APTLY_CONFIG repo create $repo
        elif [ "$FORCE_PUBLISH" != "y" ] && [ "$has_error" == "n" ] && grep -q "Download queue: 0 items" $logfile; then
            continue
        fi

        # Import the packages to the aptly repo
        need_to_publish=y
        echo "Importing mirror $mirror to repo $repo"
        aptly -config $APTLY_CONFIG repo import $mirror $repo 'Name (~ .*)' >> ${repo}.log

        # Remove the packages in the deny list
        while IFS= read -r line
        do
            # trim the line
            local filter=$(echo $line | awk '{$1=$1};1')
            if [ -z "filter" ]; then
                continue
            fi

            aptly -config $APTLY_CONFIG repo remove $repo $filter
        done < $PACKAGES_DENY_LIST
        SAVE_WORKSPACE=y
    done
}

publish_repos()
{
    local name=$1
    local dist=$2
    local archs=$3
    local components=$4
    local distname=$(echo $dist | tr '/' '_')
    local options=
    [[ "$dist" == *-backports ]] && options="$options -notautomatic=yes -butautomaticupgrades=yes"
    local publish_archs=$archs,source
    [[ "$name"  == *jessie* ]] && publish_archs=$archs

    local repos=
    for component in $(echo $components | tr ',' ' '); do
        local repo=$(get_repo_name $name $distname $component)
        repos="$repos $repo"
    done

    local publish_dist=$distname
    local retry=5
    local publish_succeeded=n
    local wait_seconds=300

    if [ "$FORCE_PUBLISH" == "y" ]; then
        echo "Force publish mirror"
    fi

    if [ "$FORCE_OVERWITE" == "y" ]; then
        options="$options -force-overwrite"
    fi

    echo "Publish the mirror: $name/$dist/$archs/$components"

    # Publish the aptly repo with retry
    echo "Publish repos: $repos"
    if [ "$FORCE_PUBLISH_DROP" == "y" ]; then
        if aptly -config $APTLY_CONFIG publish show $publish_dist $FILESYSTEM > /dev/null 2>&1; then
            aptly -config $APTLY_CONFIG publish drop -force-drop -skip-cleanup $publish_dist $FILESYSTEM
        fi
    fi
    for ((i=1;i<=$retry;i++)); do
        echo "Try to publish $publish_dist $FILESYSTEM, retry step $i of $retry"
        if ! aptly -config $APTLY_CONFIG publish show $publish_dist $FILESYSTEM > /dev/null 2>&1; then
            echo "aptly -config $APTLY_CONFIG publish repo $options -passphrase=*** -keyring=$GPG_FILE -distribution=$publish_dist -architectures=$publish_archs -component=$components $repos $FILESYSTEM"
            if aptly -config $APTLY_CONFIG publish repo $options -passphrase="$PASSPHRASE" -keyring=$GPG_FILE -distribution=$publish_dist -architectures=$publish_archs -component=$components $repos $FILESYSTEM; then
                publish_succeeded=y
                break
            fi
        else
            echo "Publish Repos=$repos publish_dist=$publish_dist"
            if aptly -config $APTLY_CONFIG publish update -passphrase="$PASSPHRASE" -keyring=$GPG_FILE -skip-cleanup $publish_dist $FILESYSTEM; then
                publish_succeeded=y
                break
            fi
        fi

        if [ "$i" != "$retry" ]; then
            echo "Sleep $wait_seconds seconds"
            sleep $wait_seconds
        fi
    done

    if [ "$publish_succeeded" != "y" ]; then
        echo "Failed to publish $publish_dist $FILESYSTEM after $retry retries" 1>&2
        exit 1
    fi

    HAS_PUBLISH_UPDATE=y
    if [ ! -z "$PUBLISH_FLAG" ]; then
        touch "$PUBLISH_FLAG"
    fi
}

main()
{
    validate_input_variables
    prepare_workspace
    for distribution in $(echo $MIRROR_DISTRIBUTIONS | tr ',' ' '); do
        echo "update repos for url=$MIRROR_URL name=$MIRROR_NAME distribution=$distribution architectures=$MIRROR_ARICHTECTURES components=$MIRROR_COMPONENTS"
        update_repos $MIRROR_NAME "$MIRROR_URL" $distribution "$MIRROR_ARICHTECTURES" "$MIRROR_COMPONENTS"
        publish_repos $MIRROR_NAME $distribution "$MIRROR_ARICHTECTURES" "$MIRROR_COMPONENTS"
    done

    save_workspace
}

main
