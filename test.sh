#!/bin/bash
HOST_16U=()
HOST_16U_NUMA=()
HOST_8U=()
HOST_8U_NUMA=()
HOST_4U=()
HOST_4U_NUMA=()
HOST_2U=()
HOST_2U_NUMA=()
HOST_1U=()
HOST_1U_NUMA=()
CPUPRESS_STW=1   # CPU 加压开关，设为1 即加压
MEMPRESS_STW=1   # 内存带宽加压开关，设为1 即加压
CPUPRESSTYPE="stressng"    # 支持使用upress 和 stressng 两种

###### 根据hostinfo 收集不同规格虚拟机信息
SUM=0
for CORENUM in `awk '{print $2}' hostinfo  | sort | uniq`; do
    if [ $CORENUM == 16U ]; then
        for ipd in `cat hostinfo | grep $CORENUM | awk '{print $1}'`; do
            HOST_16U+=( $ipd )
            NUMAINFO=`grep "\b$ipd\b" hostinfo | awk '{print $3}'`
            HOST_16U_NUMA+=( $NUMAINFO )
            ((SUM++))
        done
    elif [ $CORENUM == 8U ]; then
        for ipd in `cat hostinfo | grep $CORENUM | awk '{print $1}'`; do
            HOST_8U+=( $ipd )
            NUMAINFO=`grep "\b$ipd\b" hostinfo | awk '{print $3}'`
            HOST_8U_NUMA+=( $NUMAINFO )
            ((SUM++))
        done
    elif [ $CORENUM == 4U ]; then
        for ipd in `cat hostinfo | grep $CORENUM | awk '{print $1}'`; do
            HOST_4U+=( $ipd )
            NUMAINFO=`grep "\b$ipd\b" hostinfo | awk '{print $3}'`
            HOST_4U_NUMA+=( $NUMAINFO )
            ((SUM++))
        done
    elif [ $CORENUM == 2U ]; then
        for ipd in `cat hostinfo | grep $CORENUM | awk '{print $1}'`; do
            HOST_2U+=( $ipd )
            NUMAINFO=`grep "\b$ipd\b" hostinfo | awk '{print $3}'`
            HOST_2U_NUMA+=( $NUMAINFO )
            ((SUM++))
        done
    elif [ $CORENUM == 1U ]; then
        for ipd in `cat hostinfo | grep $CORENUM | awk '{print $1}'`; do
            HOST_1U+=( $ipd )
            NUMAINFO=`grep "\b$ipd\b" hostinfo | awk '{print $3}'`
            HOST_1U_NUMA+=( $NUMAINFO )
            ((SUM++))
        done
    fi
done

echo "-----------------------------------------------"
echo "VM sumary:"
echo -e "\tThere are \"${#HOST_16U[@]}\"\t16U VMs"
#echo "    List here : ${HOST_16U[@]}"
echo -e "\tThere are \"${#HOST_8U[@]}\"\t8U  VMs"
#echo "    List here : ${HOST_8U[@]}"
echo -e "\tThere are \"${#HOST_4U[@]}\"\t4U  VMs"
#echo "    List here : ${HOST_4U[@]}"
echo -e "\tThere are \"${#HOST_2U[@]}\"\t2U  VMs"
#echo "    List here : ${HOST_2U[@]}"
echo -e "\tThere are \"${#HOST_1U[@]}\"\t1U  VMs"
#echo "    List here : ${HOST_1U[@]}"
echo "$SUM in sum"
echo "-----------------------------------------------"

function get_press_cfg #presstype #press
{
    presstype=$1
    press=$2
    if [ ! -f press.cfg ]; then
        echo "===> \"press.cfg\" not found, please check"
        exit -1
    fi
    CPUPRESSCFG=`grep "^CPU" press.cfg | grep "$presstype" | grep "p$press" `
    MEMPRESSCFG=`grep "^MEM" press.cfg | grep "$presstype" | grep "p$press" `
    PRESS_16U=`echo $CPUPRESSCFG | awk -F ',' '{print $8}'`
    PRESS_8U=`echo $CPUPRESSCFG | awk -F ',' '{print $7}'`
    PRESS_4U=`echo $CPUPRESSCFG | awk -F ',' '{print $6}'`
    PRESS_2U=`echo $CPUPRESSCFG | awk -F ',' '{print $5}'`
    PRESS_1U=`echo $CPUPRESSCFG | awk -F ',' '{print $4}'`
    MEMPRESS_16U=`echo $MEMPRESSCFG | awk -F ',' '{print $8}'`
    MEMPRESS_8U=`echo $MEMPRESSCFG | awk -F ',' '{print $7}'`
    MEMPRESS_4U=`echo $MEMPRESSCFG | awk -F ',' '{print $6}'`
    MEMPRESS_2U=`echo $MEMPRESSCFG | awk -F ',' '{print $5}'`
    MEMPRESS_1U=`echo $MEMPRESSCFG | awk -F ',' '{print $4}'`
}


function check_stream_exec
{
    rm -f stream 
    if [ -f stream.c -o -f stream.bak ]; then
        gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=64000000 -DNTIMES=10 stream.c -o stream && ./stream &> /dev/null
        if [ $? -eq 0 ]; then
            echo "stream compiled and ready to run"
            return
        else
            echo "Compile stream error, will try other backup"
        fi
        chmod +x stream.bak && ./stream.bak &> /dev/null
        if [ $? -eq 0 ]; then
            cp stream.bak stream
            chmod +x stream
        else
            echo "There is no stream.bak for backup, cannot do memory press, please check"
            exit -1
        fi
    else
        echo "There is no stream.c for compile and no stream.bak for backup, cannot do memory press, please check"
        exit -1
    fi
}

# 产生内存带宽压力
# 参数：
#    @ CORES：虚拟机核数（程序将使用taskset 指定在最后一个核上运行，比如4U 就是指定在cpu3 上加压）
#    @ TARGET_IP：添加压力的虚拟机IP
#    @ PRESS：加压百分比， 
function gene_mbw_press #CORES $TARGET_IP #PRESS
{
    CORES=$1
    TARGET_IP=$2
    if [ $3 ] ;then
        PRESS=$3
    else
        PRESS=$MEMPRESS
    fi
    # 准备脚本  
    cat > run-mbw-press.sh <<EOF
#!/bin/bash
PRESS=$PRESS
BASEDIR=\`pwd\`
IPaddr=`ifconfig eth0 | grep inet | grep netmask | awk '{print $2}'`

### Set cgroup for cpu quota
mount | grep cgroup | grep cpu | grep -v cpuset &> /dev/null
if [ \$? -ne 0 ] ;then
    echo "Cgroups not mounted, please check"
    echo "you may try: mount -t cgroup -o remount,cpu,cpuset,memory default /sys/fs/cgroup/"
    exit
fi
CGCPUDIR=\`mount | grep cgroup | grep cpu | grep -v cpuset | awk '{print \$3}'\`
if [ ! -d \$CGCPUDIR/press_$PRESS ]; then
    mkdir \$CGCPUDIR/press_$PRESS 
fi
cd \$CGCPUDIR/press_$PRESS
PERIODUS=\`cat cpu.cfs_period_us\`
((SETPERIOD=PERIODUS*PRESS/100))
#echo -e "Now I'm under \`pwd\` dir (\$TARGET_IP), will do:\n 1. set: \\"\$\$\\" to tasks\n 2. set: \\"\$SETPERIOD\\" to cpu.cfs_quota_us for $PRESS% press( reads: \$PERIODUS from cpu.cfs_period_us)"
echo -e "Now I'm under \`pwd\` dir (\$TARGET_IP), will do:\n 1. set: \\"\$\$\\" to tasks\n 2. set: \\"\$SETPERIOD\\" to cpu.cfs_quota_us for $PRESS% press( reads: \$PERIODUS from cpu.cfs_period_us)" > /tmp/mempress_\$IPaddr
echo \$\$ >> tasks
echo \$SETPERIOD >> cpu.cfs_quota_us

### Start to run press
cd \$BASEDIR
pkill stream;
i=0
while true; do
#for i in \`seq 10\`; do
    echo "==> Press No.\$i"                                               >> /tmp/mempress_\$IPaddr
    taskset -c $((CORES-1)) ./stream | grep -E "Copy|Scale|Add|Triad" &>> /tmp/mempress_\$IPaddr 
done  
EOF
    chmod +x run-mbw-press.sh
    echo "Killing old memory press on $TARGET_IP"
    ssh $TARGET_IP "for pi in \`ps -aef | grep -E 'mbw|stream' | grep -v grep | awk '{print \$2,\$3}'\`; do kill -9 \$pi; done"
    if [ $PRESS -eq 0 ]; then
        return
    fi
    #ssh $TARGET_IP "kill -9 `ps fjx | grep stream | grep -v -E "grep|taskset|run-mbw-press" | awk '{print $1}'`"
    scp stream run-mbw-press.sh $TARGET_IP:~
    ssh $TARGET_IP "./run-mbw-press.sh" &
}

# 添加内存带宽压力（所有背景VM 均匀加压）
# 参数：
#    @ CORES：虚拟机核数（用于查询加压的list，如4U，就查HOST_4U 的列表）
#    @ PRESS：加压百分比 
function mem_press #CORES #PRESS
{
    CORES=$1
    PRESS=$2

    HOSTLIST_NAME="HOST_${CORES}U"
    TMP="$HOSTLIST_NAME[@]"

    for TARGET_IP in `echo ${!TMP}`; do
        echo -e "Run memory bandwidth stress on  $TARGET_IP  \t(${CORES}U VM, will press ${PRESS}%)"
        gene_mbw_press $CORES $TARGET_IP $PRESS 
    done
} 

function check_stressng_exec
{
    local BASEDIR=`pwd`
    chmod +x stress-ng &>/dev/null
    if [ -d stress-ng ]; then
        rm -rf stress-ng
    fi
    if test -x stress-ng && ./stress-ng -l 30 -c 4 -t 1 &> /dev/null ; then
        echo "yes, stress-ng is ready";
        return 0
    else
        tar -xvf stress-ng.tar.xz &>/dev/null && cd stress-ng-dir
        make &> /dev/null
        if ./stress-ng -l 30 -c 1 -t 1 &> /dev/null ; then
            echo "stress-ng compiled"
            rm -f $BASEDIR/stress-ng ;cp stress-ng $BASEDIR
        else
            if uname -a | grep aarch64 &> /dev/null; then
                rm -f $BASEDIR/stress-ng ; cp back/stress-ng-arm $BASEDIR/stress-ng
            elif uname -a | grep x86_64 &> /dev/null; then
                rm -f $BASEDIR/stress-ng ; cp back/stress-ng-x86 $BASEDIR/stress-ng
            fi
        fi
        cd $BASEDIR
        chmod +x stress-ng &>/dev/null
        if test -x stress-ng && ./stress-ng -l 30 -c 4 -t 3 &> /dev/null ; then
            echo "yes, stress-ng is ready";
            return 0
        else
            echo "===> Sorry, stress-ng is still not ready to run, please check"
            exit -1
        fi
    fi
}

# 产生CPU 压力
# 参数：
#    @ CORES：虚拟机核数（对应要给upress 加的核数）
#    @ PRESS：加压百分比 
#    @ TARGET_IP：添加压力的虚拟机IP
function gene_press #CORES $PRESS $TARGET_IP
{
    CORES=$1
    PRESS=$2
    TARGET_IP=$3
    
    if [ $CPUPRESSTYPE == "upress" ]; then    # 支持使用upress 和 stressng 两种
        echo "pkill upress;pkill stress-ng; for i in \`seq 0 $((CORES-1))\`; do taskset -c \$i ./upress -l $PRESS & done &> /dev/null " > run-cpu-press.sh
    elif [ $CPUPRESSTYPE == "stressng" ]; then
        echo "pkill upress; pkill stress-ng; ./stress-ng -c $CORES -l $PRESS &> /dev/null &" > run-cpu-press.sh
    else
        echo "===> CPUPRESSTYPE variable set wrong, only support \"upress\" and \"stressng\""
        exit -1
    fi
    chmod +x run-cpu-press.sh upress stress-ng
    ssh $TARGET_IP "pkill upress; pkill stress-ng"
    scp upress run-cpu-press.sh stress-ng $TARGET_IP:~
    ssh $TARGET_IP "./run-cpu-press.sh"
}

# 添加cpu 压力时参考NUMA（均匀加压）
# demo 参考：jishu=0; WHOLE=8; cnt=$WHOLE; ((HALF=$WHOLE/2)); for i in `echo 1 2 3 3 3 4 5 5 6 6 6 77 9 8 8`; do ((n1=$i%2));  if [ $n1 -ne 0 ]; then ((jishu++));if [ $jishu -gt $HALF ]; then continue; else echo $i; fi ; else echo $i; fi ; ((cnt--)); if [ $cnt -le 0 ]; then break; fi;  done
# 参数：
#    @ CORES：虚拟机核数（对应要给upress 加的核数）
#    @ LIST_CNT：对应该核数虚拟机的总数
#    @ PRESS_CNT：要添加压力的虚拟机数量，会均匀添加NODE0/1 的压力，如果都是NODE2 则加压时不管NUMA
#    @ PRESS：加压百分比 
function cpu_press #CORES $LIST_CNT #PRESS_CNT #PRESS
{
    CORES=$1
    LIST_CNT=$2
    PRESS_CNT=$3
    PRESS=$4

    HOSTLIST_NAME="HOST_${CORES}U"
    NUMALIST_NAME="HOST_${CORES}U_NUMA"
    node0=0
    node1=0
    ((HALF=PRESS_CNT/2))
    CNT=$PRESS_CNT

    for id in `seq ${LIST_CNT}`; do
        ((index=id-1))
        TMP="$HOSTLIST_NAME[$index]"
        TARGET_IP=${!TMP};
        TMP="$NUMALIST_NAME[$index]"
        NUMANODE=${!TMP};

        if [ $NUMANODE == "NODE0" ]; then
            ((node0++))
            if [ $node0 -gt $HALF ];then
                ((node0--))
                continue
            fi
        elif [ $NUMANODE == "NODE1" ]; then
            ((node1++))
        elif [ $NUMANODE == "NODE2" ]; then
            echo "Big VM with 2 numa"
            ((node0++))  # 欺骗最后的统计数量
        fi
        echo -e "Run cpu stress on  $TARGET_IP  \t(`ssh $TARGET_IP 'cat /proc/cpuinfo | grep processor |wc -l'`U VM, $NUMANODE), will press ${PRESS}%"
        gene_press $CORES $PRESS $TARGET_IP
        ((CNT--))
        if [ $CNT -le 0 ]; then
            break;
        fi; 
    done
    ((pressed=node0+node1))
    if [ $pressed == $PRESS_CNT ]; then
        echo "~~> All \"$PRESS_CNT\" press(${node0} N0, ${node1} N1) is in progress"
    else
        echo "~~> Generate \"$pressed\" press(${node0} N0, ${node1} N1), But you need \"$PRESS_CNT\", due to VMs of ${CORES}U is maldistribution on NUMA"
    fi
} 

####### 设置加压信息
./allreset.sh 
#1. 加压虚拟机梳理
PRESS_16U_CNT=${#HOST_16U[@]}
PRESS_8U_CNT=${#HOST_8U[@]}
PRESS_4U_CNT=${#HOST_4U[@]}
PRESS_2U_CNT=${#HOST_2U[@]}
PRESS_1U_CNT=${#HOST_1U[@]}
#2. 不同规格虚拟机加压的百分比(CPU、内存)
## 第一个参数设置全部虚拟机加压，还是部分虚拟机加压
## 设置为all 时，为计算和网络同时加压场景（因为网络加压时对CPU 占用消耗也挺大，存储不存在）
## 设置为part 时，为计算单独加压、或者计算和存储同时加压场景
press_type=$1
## 第二个参数设置的是加压百分比，从 press.cfg 文件中设置，脚本自动获取
press=$2
get_press_cfg  $press_type $press

####### 开始加压
tput bold   # Bold print.
check_stream_exec 
if [ $CPUPRESSTYPE == "stressng" ]; then
    check_stressng_exec
fi
 

for CORES in `echo "1 2 4 8 16"`; do
echo "==============================================="
echo "===> Dealling with ${CORES}U"
echo "==============================================="
    eval 'HOST_CNT=${#HOST_'"${CORES}"'U[@]}'
    PRESS_CNT_TMP=PRESS_${CORES}U_CNT

    if [ $CPUPRESS_STW -eq 1 ]; then
        echo "-----------------------------------------------"
        echo "            Start cpu press"
        echo "-----------------------------------------------"

        PRESS_TMP=PRESS_${CORES}U
        CMD="cpu_press $CORES $HOST_CNT ${!PRESS_CNT_TMP} ${!PRESS_TMP}"
        $CMD
        if [ ${!PRESS_CNT_TMP} -ne 0 -a ${!PRESS_TMP} -ne 0 ]; then
            echo "Runing : $CMD"
            echo -e "CPU Press cmd is :\n `cat run-cpu-press.sh`\n"
        else
            echo "Due to setting: \"${!PRESS_CNT_TMP}\" ${CORES}U VMs, run \"${!PRESS_TMP}\" press, won't press CPU press"
        fi
        echo "-----------------------------------------------"
    fi
    if [ $MEMPRESS_STW -eq 1 ]; then
        echo "-----------------------------------------------"
        echo "            Start mem press"
        echo "-----------------------------------------------"

        PRESS_TMP=MEMPRESS_${CORES}U
        CMD="mem_press $CORES ${!PRESS_TMP}"
	$CMD
        if [ ${!PRESS_CNT_TMP} -ne 0 -a ${!PRESS_TMP} -ne 0 ]; then
            echo "Runing : $CMD"
            echo -e "MEM Press cmd is :\n `tail -n 4 run-mbw-press.sh`\n"
        else
            echo "Due to setting: \"${!PRESS_CNT_TMP}\" ${CORES}U VMs, run \"${!PRESS_TMP}\" press, won't press memory press"
        fi
        echo "-----------------------------------------------"
    fi  
done
tput sgr0   # Reset terminal.
