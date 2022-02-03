#!/bin/bash -e

CREATE_DB=$1
MIRROR_NAME=$2

WORK_DIR=work
SOURCE_DIR=$(pwd)
SAVE_WORKSPACE=n
APTLY_CONFIG=aptly-debian.conf
PACKAGES_DENY_LIST=debian-packages-denylist.conf
ENCRIPTED_KEY_GPG=./encrypted_private_key.gpg
export GNUPGHOME=gnupg
GPG_FILE=$GNUPGHOME/mykey.gpg

STORAGE_DATA=_storage_data
STORAGE_METRIC=$STORAGE_DATA/metric
STORAGE_MIRROR_DIR=$STORAGE_DATA/aptly/$MIRROR_NAME
STORAGE_DB_DIR=$STORAGE_MIRROR_DIR/dbs
STORAGE_DB_LATEST_VERSION=$STORAGE_DATA/aptly/$MIRROR_NAME/latest_version
STORAGE_LATEST_VERSION=$STORAGE_DATA/aptly/latest_version
STORAGE_BUILDS_DIR=$STORAGE_DATA/builds
STORAGE_STATIC_WEBSITE_DIR=$STORAGE_DATA/static
STORAGE_STATIC_WEBSITE_PUBLISH_FILE=$STORAGE_DATA/static/publish_path.list
PUBLISH_FILESYSTEM_PATH=publish/$MIRROR_FILESYSTEM
PUBLISH_MIRROR_PATH=$PUBLISH_FILESYSTEM_PATH/dists/$MIRROR_NAME
HAS_PUBLISH_UPDATE=n

PUBLISH_VERSIONS_DIR=publish/versions

FILESYSTEM="filesystem:$MIRROR_FILESYSTEM:"
PUBLISHED_VERSIONS=published_versions

cd $WORK_DIR

validate_input_variables()
{
    if [ -z "$MIRROR_NAME" ]; then
        echo "DIST is empty" 1>&2
        exit 1
    fi

    if [ -z "$GPG_KEY" ]; then
        echo "The encrypted gpg key is not set." 1>&2
        exit 1
    fi

    if [ -z "$MIRROR_VERSION" ]; then
        echo "The MIRROR_VERSION env is not set." 1>&2
        exit 1
    fi

    if [ -z "$PASSPHRASE" ]; then
        echo "The passphrase is not set." 1>&2
        exit 1
    fi

    if ! readlink _storage_data > /dev/null; then
        echo "$WORK_DIR/_storage_data is not a symbol link" 1>&2
        exit 1
    fi  
}

prepare_workspace()
{
    echo "pwd=$(pwd)"
    mkdir -p $STORAGE_DB_DIR $STORAGE_METRIC
    rm -f $PUBLISHED_VERSIONS
    touch $PUBLISHED_VERSIONS
    cp $SOURCE_DIR/azure-pipelines/config/aptly-debian.conf $APTLY_CONFIG
    cp $SOURCE_DIR/azure-pipelines/config/debian-packages-denylist.conf $PACKAGES_DENY_LIST

    # Import gpg key
    rm -rf $GNUPGHOME
    mkdir $GNUPGHOME
    echo "pinentry-mode loopback" > $GNUPGHOME/gpg.conf
    echo "$GPG_KEY" > $ENCRIPTED_KEY_GPG
    chmod 600 $GNUPGHOME/*
    chmod 700 $GNUPGHOME
    gpg --no-default-keyring --passphrase="$PASSPHRASE" --keyring=$GPG_FILE --import "$ENCRIPTED_KEY_GPG"

    if [ -e db ]; then
        rm -rf db
    fi

    if [ "$CREATE_DB" == "y" ]; then
        return
    fi
    local latest_db=$(ls -Ar $STORAGE_DB_DIR/db-*.gz 2>/dev/null | head -n 1)
    if [ -z "$latest_db" ]; then
        #echo "Please create the aptly database and try again." 1>&2
        #exit 1
        echo "The database is empty, create a new database"
        return
    fi

    echo "The latest db file is $latest_db."
    tar -xzvf "$latest_db" -C .
}

save_workspace()
{
    local package="$STORAGE_DB_DIR/db-$(date +%Y%m%d%H%M%S).tar.gz"
    local public_key_file_asc=publish/public_key.asc
    local public_key_file_gpg=publish/public_key.gpg

    if [ "$SAVE_WORKSPACE" == "n" ]; then
        return
    fi

    if [ "$UPDATE_MIRROR" != "y" ]; then
        return
    fi

    gpg --no-default-keyring --keyring=$GPG_FILE --export -a > "$public_key_file_asc"
    gpg --no-default-keyring --keyring=$GPG_FILE --export > "$public_key_file_gpg"
    tar -czvf "$package" db
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
            if [ "$UPDATE_MIRROR" != "y" ]; then
                echo "The mirror does not exit $mirror, not to create it, since UPDATE_MIRROR=$UPDATE_MIRROR" 1>&2
                exit 1
            fi
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
        if [ "$UPDATE_MIRROR" != "y" ]; then
            echo "Skip to update the mirror $mirror, UPDATE_MIRROR=$UPDATE_MIRROR"
            continue
        fi
        
        local success=n
        local has_error=n
        local retry=5
        # Update the aptly mirror with retry
        for ((i=1;i<=$retry;i++)); do
            echo "Try to update the mirror, retry step $i of $retry"
            aptly -config $APTLY_CONFIG -ignore-signatures mirror update -max-tries=5 $mirror | tee $logfile
            if [ "$?" -eq "0" ]; then
                echo "Successfully update the mirror $mirror"
                success=y
                break
            else
                echo "Failed to update the mirror $mirror, sleep 10 seconds"
                sleep 10
                has_error=y
            fi
        done
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
        echo $MIRROR_VERSION > $STORAGE_MIRROR_DIR/version-${distname}
        echo $MIRROR_VERSION > $STORAGE_MIRROR_DIR/version
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
    [[ "$dist" == *-backports ]] && options="-notautomatic=yes -butautomaticupgrades=yes"
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

    local db_version=0
    local published_version=1
    local db_version_file=$STORAGE_MIRROR_DIR/version-${distname}
    local published_version_file=$PUBLISH_VERSIONS_DIR/version-${name}-${distname}
    [ -f $db_version_file ] && db_version=$(cat $db_version_file)
    [ -f $published_version_file ] && published_version=$(cat $published_version_file)

    # Check if the version has already published
    if [ "FORCE_PUBLISH" != "y" ] && [ "$db_version" == "$published_version" ]; then
        echo "Skip to publish $name/$dist/$archs/$components, the latest version is $db_version"
        return
    fi

    if [ "FORCE_PUBLISH" == "y" ]; then
        echo "Force publish mirror"
    fi

    echo "db_version_file=$(realpath $db_version_file)"
    echo "Publish the mirror: $name/$dist/$archs/$components, db_version=$db_version, published_version=$published_version"

    # Publish the aptly repo with retry
    echo "Publish repos: $repos"
    if [ "$FORCE_PUBLISH_DROP" == "y" ]; then
        if aptly -config $APTLY_CONFIG publish show $publish_dist $FILESYSTEM > /dev/null 2>&1; then
            mv publish publish.bk
            mkdir publish
            aptly -config $APTLY_CONFIG publish drop -force-drop -skip-cleanup $publish_dist $FILESYSTEM
            mv publish publish.bk1
            mv publish.bk publish
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

    # Update the published version of the distribution
    echo $db_version > $published_version_file
    echo $db_version >> $PUBLISHED_VERSIONS

    HAS_PUBLISH_UPDATE=y
    if [ ! -z "$PUBLISH_FLAG" ]; then
        touch "$PUBLISH_FLAG"
    fi
}

publish_static_website_index()
{
    if [ "$HAS_PUBLISH_UPDATE" != y ]; then
        echo "Skip to publish static website for not publish updated"
        return
    fi
    echo publish > publish_path_dists.list
    echo $PUBLISH_FILESYSTEM_PATH >> publish_path_dists.list 
    find $PUBLISH_FILESYSTEM_PATH/dists -type d >> publish_path_dists.list
    echo "Publish static website for $PUBLISH_MIRROR_PATH by diff"
    mkdir -p $STORAGE_STATIC_WEBSITE_DIR
    touch $STORAGE_STATIC_WEBSITE_PUBLISH_FILE
    cp $SOURCE_DIR/azure-pipelines/static/html/azure_storage_index.html ./
    grep -h Filename: $(find "$PUBLISH_MIRROR_PATH" -name Packages) | sed "s#^Filename: #$PUBLISH_FILESYSTEM_PATH/#" \
     | sed 's#\/[^\/]\+$##g' | sort | uniq > publish_path_pool.list
    cat publish_path_dists.list publish_path_pool.list | sort | uniq > publish_path_current.list
    comm -13 $STORAGE_STATIC_WEBSITE_PUBLISH_FILE publish_path_current.list > publish_path.diff
    while read -r static_path; do
        echo "Make static index for $static_path"
        if [ -d $static_path ]; then
            cp azure_storage_index.html $static_path/
        else
            echo "The path $static_path does not exist" 1>&2
        fi
    done < publish_path.diff

    echo "Update $STORAGE_STATIC_WEBSITE_PUBLISH_FILE"
    cat $STORAGE_STATIC_WEBSITE_PUBLISH_FILE publish_path.diff | sort | uniq > publish_path.list
    cp publish_path.list $STORAGE_STATIC_WEBSITE_PUBLISH_FILE
    "Publish static website for $PUBLISH_MIRROR_PATH complete"
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

    # Update the latest version of the distributions in the mirror
    local version=$(sort $PUBLISHED_VERSIONS | tail -n 1)
    if [ ! -z "$version" ]; then
        echo $version > $PUBLISH_VERSIONS_DIR/version-${MIRROR_NAME}
    fi
    publish_static_website_index
    save_workspace
}

main
