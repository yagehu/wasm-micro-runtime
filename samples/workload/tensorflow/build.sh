#!/bin/bash

####################################
#   build tensorflow-lite sample   #
####################################
set -x
set -e

EMSDK_WASM_DIR="$EM_CACHE/wasm"
BUILD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR=${BUILD_SCRIPT_DIR}/out
TENSORFLOW_DIR="${BUILD_SCRIPT_DIR}/tensorflow"
TF_LITE_BUILD_DIR=${TENSORFLOW_DIR}/tensorflow/lite/tools/make
WAMR_DIR="${BUILD_SCRIPT_DIR}/../../../product-mini/platforms/linux"

function Clear_Before_Exit
{
    [[ -f ${TENSORFLOW_DIR}/tf_lite.patch ]] &&
       rm -f ${TENSORFLOW_DIR}/tf_lite.patch
    # resume the libc.a under EMSDK_WASM_DIR
    cd ${EMSDK_WASM_DIR}
    mv libc.a.bak libc.a
}

# 1.hack emcc
cd ${EMSDK_WASM_DIR}
# back up libc.a
cp libc.a libc.a.bak
# delete some objects in libc.a
emar d libc.a open.o
emar d libc.a mmap.o
emar d libc.a munmap.o
emranlib libc.a

# 2. build tf-lite
cd ${BUILD_SCRIPT_DIR}
# 2.1 clone tf repo from Github and checkout to 2303ed commit
if [ ! -d "tensorflow" ]; then
    git clone https://github.com/tensorflow/tensorflow.git
fi

cd ${TENSORFLOW_DIR}
git checkout 2303ed4bdb344a1fc4545658d1df6d9ce20331dd

# 2.2 copy the tf-lite.patch to tensorflow_root_dir and apply
cd ${TENSORFLOW_DIR}
cp ${BUILD_SCRIPT_DIR}/tf_lite.patch .
git checkout tensorflow/lite/tools/make/Makefile
git checkout tensorflow/lite/tools/make/targets/linux_makefile.inc

if [[ $(git apply tf_lite.patch 2>&1) =~ "error" ]]; then
    echo "git apply patch failed, please check tf-lite related changes..."
    Clear_Before_Exit
    exit 0
fi

cd ${TF_LITE_BUILD_DIR}
# 2.3 download dependencies
if [ ! -d "${TF_LITE_BUILD_DIR}/downloads" ]; then
    source download_dependencies.sh
fi

# 2.4 build tf-lite target
if [ -d "${TF_LITE_BUILD_DIR}/gen" ]; then
    rm -fr ${TF_LITE_BUILD_DIR}/gen
fi
make -j 4 -C "${TENSORFLOW_DIR}" -f ${TF_LITE_BUILD_DIR}/Makefile $@

# 2.5 copy /make/gen target files to out/
rm -rf ${OUT_DIR}
mkdir ${OUT_DIR}
cp -r ${TF_LITE_BUILD_DIR}/gen/linux_x86_64/bin/. ${OUT_DIR}/

# 3. build iwasm with pthread and libc_emcc enable
cd ${WAMR_DIR}
rm -fr build && mkdir build
cd build && cmake .. -DWAMR_BUILD_LIB_PTHREAD=1 -DWAMR_BUILD_LIBC_EMCC=1
make

# 4. run tensorflow with iwasm
cd ${BUILD_SCRIPT_DIR}
# 4.1 download tf-lite model
if [ ! -f mobilenet_quant_v1_224.tflite ]; then
    wget "https://storage.googleapis.com/download.tensorflow.org/models/tflite/mobilenet_v1_224_android_quant_2017_11_08.zip"
    unzip mobilenet_v1_224_android_quant_2017_11_08.zip
fi

# 4.2 run tf-lite model with iwasm
echo "---> run tensorflow benchmark model with iwasm"
${WAMR_DIR}/build/iwasm --heap-size=10475860 \
                        ${OUT_DIR}/benchmark_model.wasm \
                        --graph=mobilenet_quant_v1_224.tflite --max_secs=300

Clear_Before_Exit


