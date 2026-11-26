#!/bin/bash

# Build the host graphics/compute driver bundle used by Nix applications.
#
# Nixpkgs' libglvnd and Vulkan loader look for drivers in /run/opengl-driver.
# On NixOS that directory contains drivers built from the same nixpkgs as the
# applications. This image deliberately uses the *host* drivers instead, so
# they always match the running kernel and GPU stack (including CUDA and
# ROCm/OpenCL compute).
#
# The bundle is bind-mounted at /run/opengl-driver by
# gregos-nix-graphics.service; every file here is a regular file or a text
# manifest, never a symlink. The image build copies the host driver dependency
# closure, rewrites its library paths to the runtime directory and patches
# each ELF with an RPATH that keeps the closure self-contained. This avoids
# both the rpm-ostree chunker's corrupted-symlink bug and the most common
# host/nix ABI mixing problem.
#
# The image ships Fedora's Nix, which is linked against the image's own glibc;
# Nix applications from the store bring their own glibc. If a copied host
# driver needs a newer GLIBC symbol version than the image provides (for
# example a library from an external ROCm tree), the image build fails instead
# of producing a subtly broken runtime.

set -euo pipefail

bundle=/usr/lib/gregos/nix-graphics
rpath="/run/opengl-driver/lib:/run/opengl-driver/lib/dri:\$ORIGIN"

if ! command -v patchelf >/dev/null 2>&1 \
    || ! command -v readelf >/dev/null 2>&1 \
    || ! command -v jq >/dev/null 2>&1; then
    dnf5 install -y patchelf binutils jq
fi

image_glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"

rm -rf "${bundle}"
install -d "${bundle}/lib" "${bundle}/lib/dri" "${bundle}/share"

declare -A added=()
declare -A canonical=()
declare -a libs=()
declare -a missing=()

resolve_host_lib() {
    local lib="$1" dir found

    if [[ "${lib}" = /* ]]; then
        if [[ -e "${lib}" ]]; then
            printf '%s\n' "${lib}"
            return 0
        fi
        return 1
    fi

    for dir in /usr/lib64 /usr/lib /lib64 /lib /usr/lib64/mangohud /opt/rocm/lib; do
        if [[ -e "${dir}/${lib}" ]]; then
            printf '%s\n' "${dir}/${lib}"
            return 0
        fi
    done

    found="$(ldconfig -p 2>/dev/null | awk -v name="${lib}" '$1 == name { print $NF; exit }')"
    if [[ -n "${found}" ]]; then
        printf '%s\n' "${found}"
        return 0
    fi

    return 1
}

add_lib() {
    local src="$1" destdir="${2:-lib}" base rel real first

    if [[ -L "${src}" && ! -e "${src}" ]]; then
        return 0
    fi
    [[ -e "${src}" || -L "${src}" ]] || return 0
    base="$(basename "${src}")"
    rel="${destdir}/${base}"

    # Container-runtime integration, not a graphics driver; never ship it.
    case "${base}" in
        libnvidia-container*) return 0 ;;
    esac

    if [[ -n "${added[${rel}]:-}" ]]; then
        return 0
    fi
    added["${rel}"]=1
    libs+=("${rel}")

    install -d "$(dirname "${bundle}/${rel}")"

    # Versioned libraries usually exist under several names (libfoo.so,
    # libfoo.so.1, libfoo.so.1.2.3). Copy the payload once and hardlink the
    # aliases so /usr does not carry three extra copies of large driver blobs;
    # every entry is still a regular file, never a symlink.
    real="$(readlink -f "${src}")"
    first="${canonical[${real}]:-}"
    if [[ -n "${first}" && -e "${bundle}/${first}" ]]; then
        ln -f "${bundle}/${first}" "${bundle}/${rel}"
        return 0
    fi
    canonical["${real}"]="${rel}"

    cp -L --preserve=mode,timestamps "${src}" "${bundle}/${rel}"
    patchelf --set-rpath "${rpath}" "${bundle}/${rel}"
}

add_glob() {
    local dir="$1" destdir="$2" pattern file
    shift 2

    for pattern in "$@"; do
        for file in "${dir}"/${pattern}; do
            [[ -e "${file}" || -L "${file}" ]] || continue
            add_lib "${file}" "${destdir}"
        done
    done
}

# Mesa/OpenGL/EGL/Vulkan/VA-API/VDPAU. The glvnd loaders themselves are
# intentionally not copied: Nix applications must keep their own libGL/libEGL/
# libvulkan from the Nix store. Only the vendor and DRI plugins use this path.
#
# On gregOS-nova this is the entire NVIDIA stack: libvulkan_nouveau.so (NVK)
# and the nouveau/zink DRI drivers. There is no proprietary userspace to copy.
add_glob /usr/lib64 lib \
    'libGLX_*.so*' 'libEGL_*.so*' 'libGLESv1_CM_*.so*' 'libGLESv2_*.so*' \
    'libglapi.so*' 'libvulkan_*.so*' 'libva*.so*' 'libvdpau*.so*'
# Layers whose manifest uses a relative library_path (VkLayer_MESA_device_select)
# are resolved through LD_LIBRARY_PATH, so their libraries must be here even
# though the manifests themselves stay in /usr/share. Manifests that name an
# absolute path keep loading their host copy, exactly as for host apps.
add_glob /usr/lib64 lib 'libVkLayer_*.so*'
add_glob /usr/lib64/dri lib/dri '*.so'
if [[ -d /usr/lib64/vdpau ]]; then
    add_glob /usr/lib64/vdpau lib/vdpau '*.so*'
fi

# NVIDIA userspace driver and CUDA/compute runtime interfaces.
add_glob /usr/lib64 lib \
    'libnvidia-*.so*' 'libcuda*.so*' 'libnvcuvid*.so*' 'libnvoptix*.so*' \
    'libcudadebugger*.so*' 'libnvEncode*.so*'

# ROCm, Level Zero and OpenCL vendor implementations. The host kernel driver
# (amdgpu and /dev/kfd for ROCm) is what makes these usable; the user-space
# libraries are exposed through the bundle where Nix applications can find
# them.
add_glob /usr/lib64 lib \
    'libhsa-runtime64.so*' 'libamdhip64.so*' 'librocblas*.so*' \
    'librocsolver*.so*' 'librocfft*.so*' 'libmiopen*.so*' 'libhip*.so*' \
    'libze_*.so*' 'libRusticlOpenCL.so*' 'libigdrcl.so*' 'libnvidia-opencl.so*'
if [[ -d /opt/rocm/lib ]]; then
    add_glob /opt/rocm/lib lib 'lib*.so*'
fi

# The dependency closure and validation run after all descriptors have added
# their libraries, so vendor ICD implementations are included too.

# JSON descriptors: rewrite library_path to the runtime bundle path. The
# descriptor files themselves stay regular files in the image and are linked
# into /run by the boot service.
rewrite_json() {
    local src="$1" out="$2" field="$3" lib resolved base

    lib="$(jq -r "${field} // empty" "${src}")"
    [[ -n "${lib}" && "${lib}" != "null" ]] || return 0
    lib="${lib//\$LIB/lib64}"

    resolved="$(resolve_host_lib "${lib}" || true)"
    if [[ -z "${resolved}" ]]; then
        missing+=("${lib} (library_path in ${src})")
        return 0
    fi

    base="$(basename "${resolved}")"
    add_lib "${resolved}" lib
    install -d "$(dirname "${out}")"
    jq --arg path "/run/opengl-driver/lib/${base}" \
        "${field} = \$path" "${src}" > "${out}"
}

for src in /usr/share/vulkan/icd.d/*.json; do
    [[ -e "${src}" ]] || continue
    case "${src}" in
        *.i686.json) continue ;;
    esac
    rewrite_json "${src}" "${bundle}/share/vulkan/icd.d/$(basename "${src}")" '.ICD.library_path'
done

# Vulkan layers are deliberately not bundled: the loader always scans the
# host layer directories in addition to VK_LAYER_PATH, so shipping the same
# layers here would load each one twice. Nix applications get layers from
# their own Nix profile (nix shell sets XDG_DATA_DIRS).

for src in /usr/share/glvnd/egl_vendor.d/*.json; do
    [[ -e "${src}" ]] || continue
    rewrite_json "${src}" "${bundle}/share/glvnd/egl_vendor.d/$(basename "${src}")" \
        '.ICD.library_path'
done

for src in /usr/share/egl/egl_external_platform.d/*.json; do
    [[ -e "${src}" ]] || continue
    rewrite_json "${src}" "${bundle}/share/egl/egl_external_platform.d/$(basename "${src}")" \
        '.ICD.library_path'
done

for icd_dir in /etc/OpenCL/vendors /usr/share/OpenCL/vendors; do
    for src in "${icd_dir}"/*.icd; do
        [[ -e "${src}" ]] || continue
        lib="$(head -n1 "${src}" | tr -d '[:space:]')"
        [[ -n "${lib}" ]] || continue
        lib="${lib//\$LIB/lib64}"
        resolved="$(resolve_host_lib "${lib}" || true)"
        if [[ -z "${resolved}" ]]; then
            missing+=("${lib} (OpenCL ICD ${src})")
            continue
        fi
        base="$(basename "${resolved}")"
        add_lib "${resolved}" lib
        install -d "${bundle}/share/OpenCL/vendors"
        printf '%s\n' "/run/opengl-driver/lib/${base}" \
            > "${bundle}/share/OpenCL/vendors/$(basename "${src}")"
    done
done

# Resolve the complete ELF dependency closure. Core glibc libraries are
# provided by whichever glibc loads the application (the image's glibc for
# Fedora's Nix, the application's own glibc for Nix-store programs); everything
# else is copied so the driver copies never search a host path that could mix
# a second glibc into a Nix process.
core_lib_re='^(libc|libm|libpthread|libdl|librt|libutil|libresolv|libanl|libnsl|libmvec|libnss_|ld-linux).*\.so'
loader_lib_re='^(libGL|libEGL|libGLESv1_CM|libGLESv2|libGLX|libGLdispatch|libOpenCL|libvulkan)\.so'

queue=("${libs[@]}")
while ((${#queue[@]})); do
    rel="${queue[0]}"
    queue=("${queue[@]:1}")
    file="${bundle}/${rel}"

    while IFS= read -r needed; do
        [[ -n "${needed}" ]] || continue
        if [[ "${needed}" =~ ${core_lib_re} || "${needed}" =~ ${loader_lib_re} ]]; then
            continue
        fi

        resolved="$(resolve_host_lib "${needed}" || true)"
        if [[ -z "${resolved}" ]]; then
            missing+=("${needed} (needed by ${rel})")
            continue
        fi

        before=${#libs[@]}
        add_lib "${resolved}" lib
        if (( ${#libs[@]} > before )); then
            queue+=("lib/${resolved##*/}")
        fi
    done < <(LC_ALL=C readelf -d "${file}" 2>/dev/null \
        | awk '/\(NEEDED\)/ { gsub(/\[|\]/, "", $NF); print $NF }')
done

if ((${#missing[@]})); then
    printf 'host graphics dependency closure is incomplete:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

# If a host driver was built against a newer glibc than the image ships, it
# cannot be loaded safely here. Fail the image build instead of shipping an
# acceleration setup that crashes at runtime.
if [[ -n "${image_glibc}" ]]; then
    for rel in "${libs[@]}"; do
        host_glibc="$(LC_ALL=C readelf --version-info "${bundle}/${rel}" 2>/dev/null \
            | grep -o 'GLIBC_2\.[0-9]*' \
            | sed 's/^GLIBC_//' \
            | sort -V \
            | tail -n1 || true)"
        [[ -n "${host_glibc}" ]] || continue

        newest="$(printf '%s\n%s\n' "${image_glibc}" "${host_glibc}" | sort -V | tail -n1)"
        if [[ "${newest}" != "${image_glibc}" ]]; then
            echo "${rel} requires GLIBC_${host_glibc}, but the image provides ${image_glibc}" >&2
            exit 1
        fi
    done
fi

# The manifest is consumed by gregos-nix-graphics.service, which validates the
# bundle before bind-mounting it at /run/opengl-driver. Keeping only regular
# files outside /run means the OCI chunker never sees the
# symlink-plus-SELinux-xattr pattern it corrupts.
printf '%s\n' "${libs[@]}" | sort -u > "${bundle}/libs.list"

vulkan_icds="$(find "${bundle}/share/vulkan/icd.d" -maxdepth 1 -type f -name '*.json' \
    -printf '/run/opengl-driver/share/vulkan/icd.d/%f\n' 2>/dev/null | paste -sd: - || true)"
egl_vendors="$(find "${bundle}/share/glvnd/egl_vendor.d" -maxdepth 1 -type f -name '*.json' \
    -printf '/run/opengl-driver/share/glvnd/egl_vendor.d/%f\n' 2>/dev/null | paste -sd: - || true)"
egl_platforms=""
if compgen -G "${bundle}/share/egl/egl_external_platform.d/*.json" >/dev/null; then
    egl_platforms=/run/opengl-driver/share/egl/egl_external_platform.d
fi
opencl_vendors=""
if compgen -G "${bundle}/share/OpenCL/vendors/*.icd" >/dev/null; then
    opencl_vendors=/run/opengl-driver/share/OpenCL/vendors
fi
vdpau_dir=""
if compgen -G "${bundle}/lib/vdpau/*.so*" >/dev/null; then
    vdpau_dir=/run/opengl-driver/lib/vdpau
fi

# LD_LIBRARY_PATH is how NixOS exposes /run/opengl-driver/lib too: Nix
# binaries do not consult /etc/ld.so.cache, so CUDA/NVML/OpenCL libraries
# that applications dlopen by soname need the bundle on the search path.
env_vars=(
    "LD_LIBRARY_PATH=/run/opengl-driver/lib"
    "LIBGL_DRIVERS_PATH=/run/opengl-driver/lib/dri"
    "LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri"
)
[[ -n "${vulkan_icds}" ]] && env_vars+=("VK_DRIVER_FILES=${vulkan_icds}")
[[ -n "${vulkan_icds}" ]] && env_vars+=("VK_ICD_FILENAMES=${vulkan_icds}")
[[ -n "${egl_vendors}" ]] && env_vars+=("__EGL_VENDOR_LIBRARY_FILENAMES=${egl_vendors}")
[[ -n "${egl_platforms}" ]] && env_vars+=("__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS=${egl_platforms}")
[[ -n "${opencl_vendors}" ]] && env_vars+=("OCL_ICD_VENDORS=${opencl_vendors}")
[[ -n "${vdpau_dir}" ]] && env_vars+=("VDPAU_DRIVER_PATH=${vdpau_dir}")

env_file=/usr/lib/environment.d/20-gregos-nix-graphics.conf
profile_file=/etc/profile.d/20-gregos-nix-graphics.sh

{
    echo "# gregOS: host graphics/compute drivers for Nix applications"
    printf '%s\n' "${env_vars[@]}"
} > "${env_file}"

{
    echo "# gregOS: host graphics/compute drivers for Nix applications"
    printf 'export %s\n' "${env_vars[@]}"
} > "${profile_file}"
chmod 0644 "${env_file}" "${profile_file}"

set_environment() {
    local key="${1%%=*}" value="${1#*=}"
    if grep -q "^${key}=" /etc/environment 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" /etc/environment
    else
        printf '%s=%s\n' "${key}" "${value}" >> /etc/environment
    fi
}

for env_var in "${env_vars[@]}"; do
    set_environment "${env_var}"
done

echo "Host graphics bundle: ${#libs[@]} libraries, ${vulkan_icds:+Vulkan ICDs, }${egl_vendors:+EGL vendors, }${opencl_vendors:+OpenCL. }"
