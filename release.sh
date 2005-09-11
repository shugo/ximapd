#!/bin/sh

set -e

version_line=`grep '^  VERSION =' ruby/ximapd.rb`
version=`expr "$version_line" : '  VERSION = "\(.*\)"'`
svn copy -m "tagged version $version" https://projects.netlab.jp/svn/ximapd/trunk https://projects.netlab.jp/svn/ximapd/tags/$version
svn export https://projects.netlab.jp/svn/ximapd/tags/$version ximapd-$version
tar zcvf ximapd-$version.tar.gz ximapd-$version
gpg -ba ximapd-$version.tar.gz
scp ximapd-$version.tar.gz{,.asc} projects.netlab.jp:/var/www/projects.netlab.jp/ximapd/releases/
