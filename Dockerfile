FROM ubuntu:18.04
USER root
WORKDIR /
SHELL ["/bin/bash", "-xo", "pipefail", "-c"]
# Creating user openvino
RUN useradd -ms /bin/bash openvino && \
    chown openvino -R /home/openvino
ARG DEPENDENCIES="autoconf \
                  automake \
                  build-essential \
                  cmake \
                  cpio \
                  curl \
                  sudo \
                  vim  \
                  wget \
                  gcc  \
                  gnupg2 \
                  libdrm2 \
                  libglib2.0-0 \
                  lsb-release \
                  libgtk-3-0 \
                  libtool \
                  udev \
                  unzip \
                  dos2unix"
RUN apt-get update && \
    apt-get install -y --no-install-recommends ${DEPENDENCIES} && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /thirdparty
RUN sed -Ei 's/# deb-src /deb-src /' /etc/apt/sources.list && \
    apt-get update && \
    apt-get source ${DEPENDENCIES} && \
    rm -rf /var/lib/apt/lists/*

# setup Python
ENV PYTHON python3.6

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3-pip python3-dev lib${PYTHON}=3.6.9-1~18.04ubuntu1.1 && \
    rm -rf /var/lib/apt/lists/*

ARG package_url=http://registrationcenter-download.intel.com/akdlm/irc_nas/16803/l_openvino_toolkit_p_2020.4.287.tgz
ARG TEMP_DIR=/tmp/openvino_installer
WORKDIR ${TEMP_DIR}
ADD ${package_url} ${TEMP_DIR}
########################################
# Install product by installation script
########################################
ENV INTEL_OPENVINO_DIR /opt/intel/openvino
RUN tar -xzf ${TEMP_DIR}/*.tgz --strip 1
RUN sed -i 's/decline/accept/g' silent.cfg && \
    ${TEMP_DIR}/install.sh -s silent.cfg && \
    ${INTEL_OPENVINO_DIR}/install_dependencies/install_openvino_dependencies.sh && \
    cd /opt/intel/openvino/install_dependencies/ && \
    sudo -E su && \
    ./install_NEO_OCL_driver.sh
WORKDIR /tmp
RUN rm -rf ${TEMP_DIR}

#############
# MYRIADX/NCS
#############

RUN usermod -aG users openvino
WORKDIR /opt
RUN curl -L https://github.com/libusb/libusb/archive/v1.0.22.zip --output v1.0.22.zip && \
    unzip v1.0.22.zip
WORKDIR /opt/libusb-1.0.22
RUN ./bootstrap.sh && \
    ./configure --disable-udev --enable-shared && \
    make -j4
RUN apt-get update && \
    apt-get install -y --no-install-recommends libusb-1.0-0-dev=2:1.0.21-2 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /opt/libusb-1.0.22/libusb
RUN /bin/mkdir -p '/usr/local/lib' && \
    /bin/bash ../libtool --mode=install /usr/bin/install -c   libusb-1.0.la '/usr/local/lib' && \
    /bin/mkdir -p '/usr/local/include/libusb-1.0' && \
    /usr/bin/install -c -m 644 libusb.h '/usr/local/include/libusb-1.0' && \
    /bin/mkdir -p '/usr/local/lib/pkgconfig'
WORKDIR /opt/libusb-1.0.22/
RUN /usr/bin/install -c -m 644 libusb-1.0.pc '/usr/local/lib/pkgconfig' && \
    ldconfig

#####################################
# Installing Dependencies For Package
#####################################
WORKDIR /tmp
RUN ${PYTHON} -m pip install --no-cache-dir setuptools && \
    find "${INTEL_OPENVINO_DIR}/" -type f -name "*requirements*.*" -path "*/${PYTHON}/*" -exec ${PYTHON} -m pip install --no-cache-dir -r "{}" \; && \
    find "${INTEL_OPENVINO_DIR}/" -type f -name "*requirements*.*" -not -path "*/post_training_optimization_toolkit/*" -not -name "*windows.txt"  -not -name "*ubuntu16.txt" -not -path "*/${PYTHON}*/*" -not -path "*/python2*/*" -exec ${PYTHON} -m pip install --no-cache-dir -r "{}" \;
WORKDIR ${INTEL_OPENVINO_DIR}/deployment_tools/open_model_zoo/tools/accuracy_checker
RUN source ${INTEL_OPENVINO_DIR}/bin/setupvars.sh && \
    ${PYTHON} -m pip install --no-cache-dir -r ${INTEL_OPENVINO_DIR}/deployment_tools/open_model_zoo/tools/accuracy_checker/requirements.in && \
    ${PYTHON} ${INTEL_OPENVINO_DIR}/deployment_tools/open_model_zoo/tools/accuracy_checker/setup.py install
WORKDIR ${INTEL_OPENVINO_DIR}/deployment_tools/tools/post_training_optimization_toolkit
RUN if [ -f requirements.txt ]; then \
        ${PYTHON} -m pip install --no-cache-dir -r ${INTEL_OPENVINO_DIR}/deployment_tools/tools/post_training_optimization_toolkit/requirements.txt && \
        ${PYTHON} ${INTEL_OPENVINO_DIR}/deployment_tools/tools/post_training_optimization_toolkit/setup.py install; \
    fi;

ARG BuildType=Release

RUN /bin/bash -c "source ${INTEL_OPENVINO_DIR}/bin/setupvars.sh && \
    mkdir -p ${INTEL_OPENVINO_DIR}/deployment_tools/open_model_zoo/demos/build && \
    cd ${INTEL_OPENVINO_DIR}/deployment_tools/open_model_zoo/demos/build && \
    cmake -DCMAKE_BUILD_TYPE=${BuildType} ../ && \
    make -j`nproc`"

###################################################
# Downloads and converts objection detection models
###################################################
RUN mkdir -p /opt/intel/openvino/downloads && \
    ${PYTHON} /opt/intel/openvino/deployment_tools/tools/model_downloader/downloader.py --name ssd300 -o /opt/intel/openvino/downloads && \
    ${PYTHON} /opt/intel/openvino/deployment_tools/tools/model_downloader/downloader.py --name ssd_mobilenet_v2_coco -o /opt/intel/openvino/downloads && \
      cd /opt/intel/openvino/downloads && \
      wget http://download.tensorflow.org/models/object_detection/ssd_mobilenet_v2_coco_2018_03_29.tar.gz && \
      tar -xzvf ssd_mobilenet_v2_coco_2018_03_29.tar.gz;

RUN mkdir -p /opt/intel/openvino/models/ssd300 && \
    cd /opt/intel/openvino/deployment_tools/model_optimizer && \
    ${PYTHON} mo.py \
    --input_proto /opt/intel/openvino/downloads/public/ssd300/models/VGGNet/VOC0712Plus/SSD_300x300_ft/deploy.prototxt \
    --input_model /opt/intel/openvino/downloads/public/ssd300/models/VGGNet/VOC0712Plus/SSD_300x300_ft/VGG_VOC0712Plus_SSD_300x300_ft_iter_160000.caffemodel \
    --output_dir /opt/intel/openvino/models/ssd300 \
    --model_name ssd300 \
    --framework caffe && \
    cp /opt/intel/openvino/deployment_tools/open_model_zoo/demos/python_demos/voc_labels.txt \
    /opt/intel/openvino/models/ssd300/ssd300.labels

RUN mkdir -p /opt/intel/openvino/models/ssd300 && \
    cd /opt/intel/openvino/deployment_tools/model_optimizer && \
    ${PYTHON} mo.py \
    --input_proto /opt/intel/openvino/downloads/public/ssd300/models/VGGNet/VOC0712Plus/SSD_300x300_ft/deploy.prototxt \
    --input_model /opt/intel/openvino/downloads/public/ssd300/models/VGGNet/VOC0712Plus/SSD_300x300_ft/VGG_VOC0712Plus_SSD_300x300_ft_iter_160000.caffemodel \
    --output_dir /opt/intel/openvino/models/ssd300 \
    --model_name ssd300_fp16 \
    --framework caffe \
    --data_type FP16 && \
    cp /opt/intel/openvino/deployment_tools/open_model_zoo/demos/python_demos/voc_labels.txt \
    /opt/intel/openvino/models/ssd300/ssd300_fp16.labels

RUN mkdir -p /opt/intel/openvino/models/ssd_mobilenet_v2_coco && \
      cd /opt/intel/openvino/deployment_tools/model_optimizer && \
      ${PYTHON} mo_tf.py \
      --input_model=/opt/intel/openvino/downloads/ssd_mobilenet_v2_coco_2018_03_29/frozen_inference_graph.pb \
      --transformations_config extensions/front/tf/ssd_support.json \
      --output="detection_boxes,detection_scores,num_detections" \
      --tensorflow_object_detection_api_pipeline_config=/opt/intel/openvino/downloads/ssd_mobilenet_v2_coco_2018_03_29/pipeline.config \
      --model_name=ssd_mobilenet_v2_coco \
      --output_dir=/opt/intel/openvino/models/ssd_mobilenet_v2_coco

COPY coco-labels-paper.txt /opt/intel/openvino/models/ssd_mobilenet_v2_coco/ssd_mobilenet_v2_coco.labels

RUN  mkdir -p /opt/intel/openvino/models/ssd_mobilenet_v2_coco && \
      cd /opt/intel/openvino/deployment_tools/model_optimizer && \
      ${PYTHON} mo_tf.py \
      --input_model=/opt/intel/openvino/downloads/ssd_mobilenet_v2_coco_2018_03_29/frozen_inference_graph.pb \
      --transformations_config extensions/front/tf/ssd_support.json \
      --output="detection_boxes,detection_scores,num_detections" \
      --tensorflow_object_detection_api_pipeline_config=/opt/intel/openvino/downloads/ssd_mobilenet_v2_coco_2018_03_29/pipeline.config \
      --model_name=ssd_mobilenet_v2_coco_fp16 \
      --data_type FP16 \
      --output_dir=/opt/intel/openvino/models/ssd_mobilenet_v2_coco

COPY coco-labels-paper.txt /opt/intel/openvino/models/ssd_mobilenet_v2_coco/ssd_mobilenet_v2_coco_fp16.labels

#############################################################
# SCRIPT FOR TAKING INPUT AS PARAMETER TO RUN CPU,GPU,MYRIADX
#############################################################
WORKDIR /opt/object_detect
COPY object_detect.sh /opt/object_detect/
RUN chmod +x /opt/object_detect/object_detect.sh
COPY http_mjpg.py /opt/object_detect/
COPY disconnected.jpg /opt/object_detect/

ENV TINI_VERSION v0.19.0
RUN mkdir -p /usr/local/bin
RUN wget -O /usr/local/bin/tini "https://github.com/krallin/tini/releases/download/$TINI_VERSION/tini"
RUN chmod +x /usr/local/bin/tini

# After copying the OpenVINO sample artifacts set the library search path
ENV LD_LIBRARY_PATH /opt/intel/openvino/opencv/lib:/opt/intel/openvino/deployment_tools/inference_engine/samples/build/intel64/lib:$LD_LIBRARY_PATH

# Post-installation cleanup and setting up OpenVINO environment variables
RUN if [ -f "${INTEL_OPENVINO_DIR}"/bin/setupvars.sh ]; then \
        printf "\nsource \${INTEL_OPENVINO_DIR}/bin/setupvars.sh\n" >> /home/openvino/.bashrc; \
        printf "\nsource \${INTEL_OPENVINO_DIR}/bin/setupvars.sh\n" >> /root/.bashrc; \
    fi;
RUN find "${INTEL_OPENVINO_DIR}/" -name "*.*sh" -type f -exec dos2unix {} \;
USER openvino

WORKDIR ${INTEL_OPENVINO_DIR}
ENTRYPOINT ["/usr/local/bin/tini", "-g", "/opt/object_detect/object_detect.sh", "--"]
#CMD ["/bin/bash"]
