#!/bin/bash

if [[ -z "$DEBUG" ]] || [[ "$DEBUG" -eq "0" ]]; then
    set -e
else
    set -ex
fi


# Configuration variables
NPROC="${NPROC:-$(nproc)}"
PIP_OPTIONS="${PIP_OPTIONS:---upgrade}"
PIP_REQUIREMENTS="${PIP_REQUIREMENTS:-}"
PYTHON_BUILD_DIR="${PYTHON_BUILD_DIR:-}"
PYTHON_CONFIG="${PYTHON_CONFIG:-}"
version="3.8.2"
PYTHON_SOURCE="${PYTHON_SOURCE:-https://www.python.org/ftp/python/${version}/Python-${version}.tgz}"

script=$(readlink -f $0)
exe_name="$(basename ${APPIMAGE:-$script})"
BASEDIR="${APPDIR:-$(readlink -m $(dirname $script))}"

prefix="usr/python"


# Parse the CLI
show_usage () {
    echo "Usage: ${exe_name} --appdir <path to AppDir>"
    echo
    echo "Bundle Python into an AppDir under \${APPDIR}/${prefix}. In addition"
    echo "extra packages can be bundled as well using \$PIP_REQUIREMENTS."
    echo "Note that if an existing install of Python already exists then no new"
    echo "install of Python is done, i.e. \${PYTHON_SOURCE} and its related"
    echo "arguments are ignored. Yet, extra \$PIP_REQUIREMENTS are installed."
    echo
    echo "Variables:"
    echo "  NPROC=\"${NPROC}\""
    echo "      The number of processors to use for building Python from a"
    echo "      source distribution"
    echo
    echo "  PIP_OPTIONS=\"${PIP_OPTIONS}\""
    echo "      Options for pip when bundling extra site-packages"
    echo
    echo "  PIP_REQUIREMENTS=\"${PIP_REQUIREMENTS}\""
    echo "      Specify extra site-packages to embed in the AppImage. Those are"
    echo "      installed with pip as requirements"
    echo
    echo "  PYTHON_BUILD_DIR=\"\""
    echo "      Set the build directory for Python. A temporary one will be"
    echo "      created otherwise"
    echo
    echo "  PYTHON_CONFIG=\"${PYTHON_CONFIG}\""
    echo "      Provide extra configuration flags for the Python build. Note"
    echo "      that the install prefix will be overwritten"
    echo
    echo "  PYTHON_SOURCE=\"${PYTHON_SOURCE}\""
    echo "      The source to use for Python. Can be a directory, an url or/and"
    echo "      an archive"
    echo
}

APPDIR=

while [[ ! -z "$1" ]]; do
    case "$1" in
        --plugin-api-version)
            echo "0"
            exit 0
            ;;
        --appdir)
            APPDIR="$2"
            shift
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Invalid argument: $1"
            echo
            show_usage
            exit 1
            ;;
    esac
done

if [[ -z "$APPDIR" ]]; then
    show_usage
    exit 1
else
    APPDIR=$(readlink -m "$APPDIR")
    mkdir -p "$APPDIR"
fi


# Setup a temporary work space
if [[ -z "${PYTHON_BUILD_DIR}" ]]; then
    PYTHON_BUILD_DIR=$(mktemp -d)

    atexit() {
        rm -rf "${PYTHON_BUILD_DIR}"
    }

    trap atexit EXIT
else
    PYTHON_BUILD_DIR=$(readlink -m "${PYTHON_BUILD_DIR}")
    mkdir -p "${PYTHON_BUILD_DIR}"
fi


# Install Python from source, if not already in the AppDir
set +e
python=$(ls "${APPDIR}/${prefix}/bin/python"?"."?)
set -e

if [[ -x "${python}" ]]; then
    echo "Found existing install under ${APPDIR}/${prefix}. Skipping Python build."
else
    # Check if the given sources are a local file or directory; if yes,
    # "save" the full path. It might've been given relative to the current
    # directory.
    if [[ -e "${PYTHON_SOURCE}" ]]; then
        PYTHON_SOURCE=$(readlink -f "${PYTHON_SOURCE}")
    fi

    cd "${PYTHON_BUILD_DIR}"
    source_file=$(basename "${PYTHON_SOURCE}")
    if [[ "${PYTHON_SOURCE}" == http* ]] || [[ "${PYTHON_SOURCE}" == ftp* ]]; then
        wget -c --no-check-certificate "${PYTHON_SOURCE}"
    else
        cp -r "${PYTHON_SOURCE}" "."
    fi
    if [[ "${source_file}" == *.tgz ]] || [[ "${source_file}" == *.tar.gz ]]; then
        if [[ "${source_file}" == *.tgz ]]; then
            dirname="${source_file%.*}"
        else
            dirname="${source_file%.*.*}"
        fi
        [[ -f $dirname ]] || tar -xzf "${source_file}"
        source_dir="$dirname"
    else
        source_dir="$source_file"
    fi

    cd "${source_dir}"
    ./configure ${PYTHON_CONFIG} "--with-ensurepip=install" "--prefix=/${prefix}" LDFLAGS="${LDFLAGS} -Wl,-rpath='"'$$ORIGIN'"/../../lib'"
    HOME="${PYTHON_BUILD_DIR}" make -j"$NPROC" DESTDIR="$APPDIR" install
fi

cd "${APPDIR}/${prefix}/bin"
PYTHON_X_Y=$(ls "python"?"."?)


# Install any extra requirements with pip
if [[ ! -z "${PIP_REQUIREMENTS}" ]]; then
    HOME="${PYTHON_BUILD_DIR}" PYTHONHOME=$(readlink -f ${PWD}/..) ./${PYTHON_X_Y} -m pip install ${PIP_OPTIONS} --upgrade pip
    HOME="${PYTHON_BUILD_DIR}" PYTHONHOME=$(readlink -f ${PWD}/..) ./${PYTHON_X_Y} -m pip install ${PIP_OPTIONS} ${PIP_REQUIREMENTS}
fi


# Prune the install
cd "$APPDIR/${prefix}"
rm -rf "bin/python"*"-config" "bin/idle"* "lib/pkgconfig" \
       "share/doc" "share/man" "lib/libpython"*".a" "lib/python"*"/test" \
       "lib/python"*"/config-"*"-x86_64-linux-gnu"


# Wrap the Python executables
cd "$APPDIR/${prefix}/bin"
set +e
pythons=$(ls "python" "python"? "python"?"."? "python"?"."?"m" 2>/dev/null)
set -e
mkdir -p "$APPDIR/usr/bin"
cd "$APPDIR/usr/bin"
for python in $pythons
do
    if [[ ! -L "$python" ]]; then
        strip "$APPDIR/${prefix}/bin/${python}"
        cp "${BASEDIR}/share/python-wrapper.sh" "$python"
        sed -i "s|[{][{]PYTHON[}][}]|$python|g" "$python"
        sed -i "s|[{][{]PREFIX[}][}]|$prefix|g" "$python"
    fi
done


# Sanitize the shebangs of local Python scripts
cd "$APPDIR/${prefix}/bin"
for exe in $(ls "${APPDIR}/${prefix}/bin"*)
do
    if [[ -x "$exe" ]] && [[ ! -d "$exe" ]]; then
        sed -i '1s|^#!.*\(python[0-9.]*\).*|#!/bin/sh\n"exec" "$(dirname $(readlink -f $\{0\}))/../../bin/\1" "$0" "$@"|' "$exe"
    fi
done


# Set a hook in Python for cleaning the path detection
cp "$BASEDIR/share/sitecustomize.py" "$APPDIR"/${prefix}/lib/python*/site-packages


# Patch binaries and install dependencies
excludelist="${BASEDIR}/share/excludelist"
if [[ ! -f "${excludelist}" ]]; then
    pushd "${BASEDIR}"
    wget -cq --no-check-certificate "https://raw.githubusercontent.com/probonopd/AppImages/master/excludelist"
    excludelist="$(pwd)/excludelist"
    popd
fi
excludelist=$(cat "${excludelist}" | sed 's|#.*||g' | sed -r '/^\s*$/d')

is_excluded () {
    local e
    for e in ${excludelist}; do
        [[ "$e" == "$1" ]] && echo "true" && return 0
    done
    return 0
}

set +e
patchelf=$(command -v patchelf)
set -e
patchelf="${patchelf:-${BASEDIR}/usr/bin/patchelf}"
if [[ ! -x "${patchelf}" ]]; then
    ARCH="${ARCH:-x86_64}"
    pushd "${BASEDIR}"
    wget -cq https://github.com/niess/patchelf.appimage/releases/download/${ARCH}/patchelf-${ARCH}.AppImage
    patchelf="$(pwd)/patchelf-${ARCH}.AppImage"
    chmod u+x "${patchelf}"
    popd
fi

patch_binary() {
    local name="$(basename $1)"

    if [[ "${name::3}" == "lib" ]]; then
        if [[ ! -f "${APPDIR}/usr/lib/${name}" ]] && [[ ! -L "${APPDIR}/usr/lib/${name}" ]]; then
            echo "Patching dependency ${name}"
            "${patchelf}" --set-rpath '$ORIGIN' "$1"
            ln -s "$2"/"$1" "${APPDIR}/usr/lib/${name}"
        fi
    else
        echo "Patching C-extension module ${name}"
        local rpath="$(${patchelf} --print-rpath $1)"
        local rel="$(dirname $(readlink -f $1))"
        rel=${rel#${APPDIR}/usr}
        rel=$(echo $rel | sed 's|/[_a-zA-Z0-9.-]*|/..|g')
        if grep -qv '$ORIGIN'"${rel}/lib" <<< "${rpath}" ; then
            [[ ! -z "${rpath}" ]] && rpath="${rpath}:"
            "${patchelf}" --set-rpath "${rpath}"'$ORIGIN'"${rel}/lib" "$1"
        fi
    fi

    local deps
    for deps in $(ldd $1); do
        if [[ "${deps::1}" == "/" ]] && [[ "${deps}" != "${APPDIR}"* ]]; then
            local lib="$(basename ${deps})"
            if [[ ! -f "${APPDIR}/usr/lib/${lib}" ]]; then
                if [[ ! "$(is_excluded ${lib})" ]]; then
                    echo "Installing dependency ${lib}"
                    cp "${deps}" "${APPDIR}/usr/lib"
                    "${patchelf}" --set-rpath '$ORIGIN' "${APPDIR}/usr/lib/${lib}"
                fi
            fi
        fi
    done
    return 0
}

cd "$APPDIR/${prefix}/bin"
[[ -f python3 ]] && ln -fs python3 python
mkdir -p "${APPDIR}/usr/lib"
cd "${APPDIR}/${prefix}/lib/${PYTHON_X_Y}"
relpath="../../${prefix}/lib/${PYTHON_X_Y}"
find "lib-dynload" -name '*.so' -type f | while read file; do patch_binary "${file}" "${relpath}"; done


# Copy any TCl/Tk shared data
#if [[ ! -d "${APPDIR}/${prefix}/share/tcltk" ]]; then
#    if [[ -d "/usr/share/tcltk" ]]; then
#        mkdir -p "${APPDIR}/${prefix}/share"
#        cp -r "/usr/share/tcltk" "${APPDIR}/${prefix}/share"
#    else
#        mkdir -p "${APPDIR}/${prefix}/share/tcltk"
#        tclpath="$(ls -d /usr/share/tcl* | tail -1)"
#        tkpath="$(ls -d /usr/share/tk* | tail -1)"
#        for path in "${tclpath}" "${tkpath}"; do
#            cp -r "${path}" "${APPDIR}/${prefix}/share/tcltk"
#        done
#    fi
#fi
