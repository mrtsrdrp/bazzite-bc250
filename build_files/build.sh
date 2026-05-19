#!/bin/bash
set -ouex pipefail

# 1. Determine kernel details from the existing base image installation
KVER=$(ls /usr/lib/modules | head -n 1)
BASE_VER=$(echo "$KVER" | cut -d'-' -f1)
MAJOR_VER=$(echo "$BASE_VER" | cut -d'.' -f1)

# 2. Install kernel development headers and build dependencies inside the builder container
dnf5 install -y git gcc make zstd wget awk kernel-devel-$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}')

# 3. Create an isolated workspace and fetch the complete AMD driver tree to satisfy relative Makefile paths
WORKSPACE=$(mktemp -d)
cd "$WORKSPACE"
wget "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/linux-${BASE_VER}.tar.xz"
tar -xf "linux-${BASE_VER}.tar.xz" --strip-components=1 "linux-${BASE_VER}/drivers/gpu/drm/amd"

# 4. Patch the amdgpu driver source code for the 40 CU unlock
GFX_SRC="drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c"

# Prepare code block injections
cat > param_patch.c << 'EOF_PARAM'
/* BC-250 40 CU unlock: clears harvest mask + enables SPI dispatch to all WGPs */
static int bc250_cc_write_mode;
module_param(bc250_cc_write_mode, int, 0444);
MODULE_PARM_DESC(bc250_cc_write_mode,
        "BC-250: 0=off 1=probe-SE0SH0 2=clear-SE0SH0 3=clear-all-SAs 4=probe-all-SAs");
#define BC250_PCI_DEVICE_ID 0x13FE
EOF_PARAM

cat > cc_patch.c << 'EOF_CC'
        /* BC-250: unlock harvested CUs — CC (enumeration) + SPI (dispatch) + RLC (power) */
        if (bc250_cc_write_mode > 0 && adev->pdev->device == BC250_PCI_DEVICE_ID) {
                int bc_se, bc_sh;
                for (bc_se = 0; bc_se < adev->gfx.config.max_shader_engines; bc_se++) {
                        for (bc_sh = 0; bc_sh < adev->gfx.config.max_sh_per_se; bc_sh++) {
                                u32 bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after;
                                if (bc250_cc_write_mode == 2 && (bc_se > 0 || bc_sh > 0))
                                        continue;
                                gfx_v10_0_select_se_sh(adev, bc_se, bc_sh, 0xffffffff, 0);
                                bc_cc_orig = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);
                                WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, 0);
                                bc_cc_after = RREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG);
                                bc_spi_orig = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);
                                WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, 0x1f);
                                bc_spi_after = RREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK);
                                WREG32_SOC15(GC, 0, mmRLC_PG_ALWAYS_ON_WGP_MASK, 0x1f);
                                if (bc250_cc_write_mode == 1 || bc250_cc_write_mode == 4) {
                                        WREG32_SOC15(GC, 0, mmCC_GC_SHADER_ARRAY_CONFIG, bc_cc_orig);
                                        WREG32_SOC15(GC, 0, mmSPI_PG_ENABLE_STATIC_WGP_MASK, bc_spi_orig);
                                        dev_info(adev->dev,
                                                "bc250-40cu-probe: se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x (restored)",
                                                bc_se, bc_sh, bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after);
                                } else {
                                        dev_info(adev->dev,
                                                "bc250-40cu-enable: mode=%d se=%d sh=%d CC=0x%08x->0x%08x SPI=0x%08x->0x%08x",
                                                bc250_cc_write_mode, bc_se, bc_sh,
                                                bc_cc_orig, bc_cc_after, bc_spi_orig, bc_spi_after);
                                }
                        }
                }
                gfx_v10_0_select_se_sh(adev, 0xffffffff, 0xffffffff, 0xffffffff, 0);
        }
EOF_CC

# Insert module parameters
sed -i "/#include \"amdgpu.h\"/r param_patch.c" "$GFX_SRC"

# Insert CC write block inside gfx_v10_0_get_cu_info after mutex_lock
awk '
/static.*gfx_v10_0_get_cu_info/ { in_cu_info = 1 }
in_cu_info && /mutex_lock/ && !inserted {
    print
    while ((getline line < "cc_patch.c") > 0) print line
    close("cc_patch.c")
    inserted = 1
    next
}
{ print }
' "$GFX_SRC" > "${GFX_SRC}.new"
mv "${GFX_SRC}.new" "$GFX_SRC"

# 5. Create a dummy directory structure to satisfy macro relative lookups
mkdir -p extra/layers

# 6. Compile the patched driver module using KCFLAGS to map the include layout
make -C "/usr/lib/modules/${KVER}/build" M="$(pwd)/drivers/gpu/drm/amd/amdgpu" KCFLAGS="-I$(pwd)/extra/layers" -j"$(nproc)" modules

# 7. Compress and replace the original kernel module in the image
TARGET_MOD="/usr/lib/modules/${KVER}/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst"
zstd -f "drivers/gpu/drm/amd/amdgpu/amdgpu.ko" -o "$TARGET_MOD"

# 8. Update module dependencies
depmod -a "${KVER}"

# 9. Create the modprobe configuration to persist the 40 CU enablement
mkdir -p /etc/modprobe.d
printf '# BC-250 40 CU re-enablement\noptions amdgpu bc250_cc_write_mode=3\n' > /etc/modprobe.d/bc250-40cu.conf

# 10. Clean up compilation tools to shrink final image footprint
dnf5 remove -y git gcc make wget kernel-devel
rm -rf "$WORKSPACE"
