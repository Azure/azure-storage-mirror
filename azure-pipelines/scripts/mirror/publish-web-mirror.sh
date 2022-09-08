#!/bin/bash -e

WORK_DIR=work
SOURCE_DIR=$(pwd)
BUILD_VERSION_URLS=build-version-urls.conf
WEB_VERSION_FILE=versions-web

cd $WORK_DIR

read_packages_per_url()
{
    local url=$1
    [ -f versions.zip ] && rm versions.zip
    [ -d versions ] && rm -rf versions
    echo "Get the version files from $url"
    wget -O versions.zip "$url" || {
      echo "Failed to download from $url, skipped
      return 0
    }
    if [ ! -f versions.zip ]; then
        echo "Failed to download versions.zip from $url" 1>&2
        exit 1
    fi
    unzip versions.zip -d versions > /dev/null
    find "versions" -name versions-web -exec sh -c 'cat {};echo ' \; | grep -v -e '^$' | sort | uniq > versions.tmp1
    touch $WEB_VERSION_FILE
    mv $WEB_VERSION_FILE versions.tmp2
    cat versions.tmp1 versions.tmp2 | sort | uniq > $WEB_VERSION_FILE
}

read_packages()
{
    rm -f $WEB_VERSION_FILE
    while IFS= read -r line
    do
        read_packages_per_url $line
    done < $BUILD_VERSION_URLS
}

publish_packages()
{
    local publish_path=$1
    local packages_path=packages
    mkdir -p $publish_path
    mkdir -p $packages_path
    while IFS= read -r line
    do
        local url=$(echo "$line" | sed -e "s/==[0-9a-fA-F]\+$//")
        local version=$(echo "$line" | sed -e "s/.*==//")
        local filename=$(echo $url | awk -F"/" '{print $NF}' | cut -d? -f1 | cut -d# -f1)
        local publish_file="$publish_path/${filename}-${version}"
        if [ "$publish_file" != "y" ] && [ -e "$publish_file" ]; then
            echo "Skipped $url, the file $publish_file exists."
            continue
        fi
        local filepath="$packages_path/$filename"
        wget -q -O "$filepath" $url
        local real_version=$(md5sum "$filepath" | cut -d " " -f1)
        if [ "$real_version" != "$version" ]; then
            echo "The file $url hash value $real_version, mismatch with expected value: $version"
        fi
        local version_filepath="$publish_path/${filename}-${real_version}"
        echo "Downloaded file $filepath, hash value: ${real_version}"
        if [ ! -e "$version_filepath" ]; then
            echo "Copy file $filepath to $version_filepath"
            cp "$filepath" "$version_filepath"
        fi
        rm -rf "$filepath"
    done < $WEB_VERSION_FILE
}

cp $SOURCE_DIR/azure-pipelines/config/build-version-urls.conf $BUILD_VERSION_URLS
read_packages
publish_packages public/packages
publish_packages public-replica/packages
