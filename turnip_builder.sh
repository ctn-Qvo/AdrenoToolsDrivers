#!/bin/bash -e

# 定义变量
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="git meson ninja patchelf unzip curl pip flex bison zip glslang glslangValidator"
workdir="$(pwd)/turnip_workdir"
base_workdir="$(pwd)"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://github.com/whitebelyash/mesa-unified"
srcfolder="mesa"

clear

# 这里共有 4 个函数，如需禁用直接注释掉即可。
# 你也可以插入自己的函数并提交 PR。
run_all(){
	echo "====== 开始构建 TU V$BUILD_VERSION！======"
	echo "当前目录: $base_workdir"
	check_deps
	prepare_workdir
	# 分支名含斜杠，需特殊处理
	build_lib_for_android turnip/gen8 turnip
	build_lib_for_android turnip/gen8 turnip-sync apply
	#build_lib_for_android gen8-yuck
}

check_deps(){
	echo "检查系统依赖 ..."
		for deps_chk in $deps;
			do
				sleep 0.25
				if command -v "$deps_chk" >/dev/null 2>&1 ; then
					echo -e "$green - 找到 $deps_chk $nocolor"
				else
					echo -e "$red - 未找到 $deps_chk，无法继续。 $nocolor"
					deps_missing=1
				fi;
			done

		if [ "$deps_missing" == "1" ]
			then echo "请安装缺失的依赖" && exit 1
		fi

	echo "安装 Python Mako 依赖（如缺失）..." $'\n'
		pip install mako &> /dev/null
}

prepare_workdir(){
	echo "准备工作目录 ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	echo "从 Google 下载 android-ndk ..." $'\n'
		curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	echo "解压 android-ndk ..." $'\n'
		unzip "$ndkver"-linux.zip &> /dev/null

	echo "下载 mesa 源码 ..." $'\n'
		git clone $mesasrc --depth=1 --no-single-branch $srcfolder
		cd $srcfolder
}

apply_patch() {
	echo "应用补丁 $1"
	if ! git apply --check $1; then
			echo "应用补丁 $1 失败！"
			exit 1
		fi
    	git apply $1
}

# $1 - 实际分支名，$2 - 转义后的分支名
build_lib_for_android(){
	echo "==== 在分支 $1 上构建 Mesa ===="
	git checkout --force origin/$1
	if [[ "$3" == "apply" ]]; then
		echo "应用补丁"
		for patch in $base_workdir/patches/*; do
			apply_patch $patch
		done
	fi
	# 用 Clang 代替 GCC
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	echo "生成构建文件 ..." $'\n'
		cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

		cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

		meson setup build-android-aarch64 \
			--cross-file "android-aarch64.txt" \
			--native-file "native.txt" \
			--prefix /tmp/turnip-$2 \
			-Dbuildtype=release \
			-Dstrip=true \
			-Dplatforms=android \
			-Dvideo-codecs= \
			-Dplatform-sdk-version="$sdkver" \
			-Dandroid-stub=true \
			-Dgallium-drivers= \
			-Dvulkan-drivers=freedreno \
			-Dvulkan-beta=true \
			-Dfreedreno-kmds=kgsl \
			-Degl=disabled \
			-Dplatform-sdk-version=36 \
			-Dandroid-libbacktrace=disabled \
			--reconfigure

	echo "编译构建文件 ..." $'\n'
		ninja -C build-android-aarch64 install

	if ! [ -a /tmp/turnip-$2/lib/libvulkan_freedreno.so ]; then
		echo -e "$red 构建失败！ $nocolor" && exit 1
	fi
	echo "打包"
	cd /tmp/turnip-$2/lib
	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "主线 Turnip v$BUILD_VERSION",
  "description": "上游 Turnip 驱动 + 一些补丁。基于分支 $1 构建",
  "author": "whitebelyash",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.335",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF
zip /tmp/mainline-$2-V$BUILD_VERSION.zip libvulkan_freedreno.so meta.json
cd -
if ! [ -a /tmp/mainline-$2-V$BUILD_VERSION.zip ]; then
	echo -e "$red 打包失败！ $nocolor"
fi
}

run_all
