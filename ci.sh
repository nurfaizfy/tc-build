#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src

set -eu

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm | upload) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    do_kernel
    do_upload
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets arm aarch64 x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    apt-get install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        gcc \
        g++ \
        git \
        libelf-dev \
        libssl-dev \
        lld \
        make \
        ninja-build \
        python3 \
        texinfo \
        xz-utils \
        zlib1g-dev
}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" fetch --depth=1 origin $branch
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['X86']}
builder.toolchain_prefix = Path('$install')

builder.build()
EOF
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)

    "$base"/build-llvm.py \
        --install-folder "$install" \
        --quiet-cmake \
        --shallow-clone \
        --show-build-commands \
        --targets ARM AArch64 X86 \
        --vendor-string "Gonon" \
        "${extra_args[@]}"
}

function do_upload() {
	cd $install
	
	#clean unused file
	find -name *.cmake -delete
	find -name *.la -delete
	find -name *.a -delete
	rm -rf stripp-* .file-idx
	
	CLANG_VERSION="$(${install}/bin/clang --version | head -n1 | cut -d' ' -f4)"
	CLANG_CONFIG="$(${install}/bin/clang -v 2>&1)"
	BINUTILS_VERSION="$(${install}/bin/aarch64-linux-gnu-addr2line --version | head -n1 | cut -d' ' -f5)"
	DATE=$(date +%Y%m%d)
	COMPRESSED_NAME="GononClang-${CLANG_VERSION}-${DATE}"
	BUILD_TAG="${CLANG_VERSION}-release"
	MESSAGE=${COMPRESSED_NAME}
	
	git config --global user.name github-actions[bot]
	git config --global user.email github-actions[bot]@users.noreply.github.com
	git clone https://nurfaizfy:"${GITHUB_TOKEN}"@github.com/Gonon-Kernel/gonon-clang ${base}/clang-repo -b main
	
	cd ${base}/clang-repo
	git commit --allow-empty -as \
		-m "${MESSAGE}" \
		-m "${CLANG_CONFIG}"
	cp -rf ${install}/* .
	tar -czvf "${COMPRESSED_NAME}.tar.gz" *
	echo ${COMPRESSED_NAME}
	hub release create -a ${COMPRESSED_NAME}.tar.gz -m "${MESSAGE}" ${BUILD_TAG}
	cd -
}

parse_parameters "$@"
do_"${action:=all}"
