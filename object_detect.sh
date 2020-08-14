#!/bin/bash

set -x

source /opt/intel/openvino/bin/setupvars.sh
export PATH=/opt/openvino/samples:$PATH

: ${TARGET:="CPU"}

openvino_model_path()
{
	if [ "$TARGET" = "MYRIAD" ]; then
		# MYRIAD supports networks with FP16 format only
		target_precision="_fp16"
	else
		target_precision=""
	fi
	echo $INTEL_CVSDK_DIR/models/ssd_mobilenet_v2_coco/$1$target_precision.xml
}

openvino_labels()
{
  if [ "$TARGET" = "MYRIAD" ]; then
                # MYRIAD supports networks with FP16 format only
                target_precision="_fp16"
        else
                target_precision=""
        fi
        echo $INTEL_CVSDK_DIR/models/ssd_mobilenet_v2_coco/$1$target_precision.labels
}

trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

touch .lock

python3.6 `dirname $0`/http_mjpg.py &

while true; do
	cp -f `dirname $0`/disconnected.jpg out.jpg
	if [ -e /run/netns/host  ]; then
		ip netns exec host $INTEL_CVSDK_DIR/deployment_tools/open_model_zoo/demos/build/intel64/Release/object_detection_demo_ssd_async \
			-d $TARGET \
			-m `openvino_model_path ssd_mobilenet_v2_coco` \
			-i $INPUT_STREAM \
		        -t 0.6 \
			-labels `openvino_labels ssd_mobilenet_v2_coco`  
	else
		$INTEL_CVSDK_DIR/deployment_tools/open_model_zoo/demos/build/intel64/Release/object_detection_demo_ssd_async \
			-d $TARGET \
			-m `openvino_model_path ssd_mobilenet_v2_coco` \
			-t 0.6 \
			-i $INPUT_STREAM \
			-labels `openvino_labels ssd_mobilenet_v2_coco`  
	fi
	sleep 1
done

wait
