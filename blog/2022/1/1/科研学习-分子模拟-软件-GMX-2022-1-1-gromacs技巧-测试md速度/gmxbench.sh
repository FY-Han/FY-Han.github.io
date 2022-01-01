#!/bin/bash
if [ $# -lt 1 ]; then
    echo 'usage: -[c number of total cores] -[r rank list] -[t thread list] -[T thread in "start step stop" format] -[g gpu id list]  -[s total step] -[S reset step] -[G type of gpu task 0:no gpu, 1:nb, 2:nb+pme, 3:nb+bf, 4:nb+pme+bf]  -[a addition options for mdrun]   input.tpr'
    exit 1
fi
while getopts ":r:t:T:c:g:G:s:S:a:" opt
do
    case $opt in
        r) RANKLIST=$OPTARG;;
        t) THREADLIST=$OPTARG;;
        T) THREADSEQ=$OPTARG;;
        c) CORES=$OPTARG;;
        g) GPUID=$OPTARG;;
        G) GPUTASK=$OPTARG;;
        s) TOTALSTEP=$OPTARG;;
        S) RESETSTEP=$OPTARG;;
        a) ADDOP=$OPTARG;;
        ?) echo 'usage: -[c number of total cores] -[r rank list] -[t thread list] -[T thread in "start step stop" format] -[g gpu id list]  -[s total step] -[S reset step] -[G type of gpu task 0:no gpu, 1:nb, 2:nb+pme, 3:nb+bf, 4:nb+pme+bf]  -[a addition options for mdrun]   input.tpr'
        exit 1;;
    esac
done
shift $(($OPTIND - 1))

MDRUN="gmx mdrun"

if [ -z $CORES ];then
    CORES=$(lscpu -p | egrep -v '^#' | sort -u -t, -k 2,4 | wc -l)
    echo "$CORES cores detected"
fi
echo "Total cores is $CORES"

if [ -z $RANKLIST ];then
    RANKLIST="1"
fi
echo "Rank list is $RANKLIST"

if [ -z "$GPUID" ];then
    ngpu=$(lspci | grep -c VGA)
    if [ $ngpu -eq 1 ];then
        GPUID="0"
    fi
    if [ $ngpu -eq 2 ];then
        GPUID="01 0"
    fi
    if [ $ngpu -eq 3 ];then
        GPUID="012 01 0"
    fi
    if [ $ngpu -eq 4 ];then
        GPUID="0123 012 01 0"
    fi
    echo "$ngpu gpus detected"
fi
echo "GPUID list is $GPUID"

if [[ -z "$THREADLIST" && -z "$THREADSEQ" ]];then
    echo "Use all the available cores only"
    ALLTHREAD=1
fi

if [ -n "$THREADSEQ" ];then
    THREADLIST=$(seq $THREADSEQ)
    echo "Thread seq is $THREADSEQ"
fi
if [ -n "$THREALIST" ];then
    echo "Thread list is $THREADLIST"
fi

if [ -z "$TOTALSTEP" ];then
    TOTALSTEP=13000   # Total steps to perform for each benchmark
fi
if [ -z "$RESETSTEP" ];then
    RESETSTEP=8000   # Total steps to perform for each benchmark
fi

if [ -z "$GPUTASK" ];then
    GPUTASK=2
fi





#==============================================================================
# Where is the benchmark MD system
#==============================================================================
TPR=$1
TPRDIR=${TPR/.tpr/}

#==============================================================================
# From the number of GPUs per node and the number of PP ranks
# determine an appropriate value for mdrun's "-gpu_id" string.
#
# GPUs will be assigned to PP ranks in order, from the lower to
# the higher IDs, so that each GPU gets approximately the same
# number of PP ranks. Here is an example of how 5 PP ranks would
# be mapped to 2 GPUs:
#            +-----+-----+-----+-----+-----+
# PP ranks:  |  0  |  1  |  2  |  3  |  4  |
#            +-----+-----+-----+-----+-----+
# GPUs:      |  0  |  0  |  0  |  1  |  1  |
#            +-----+-----+-----+-----+-----+
#
# Will consecutively use GPU IDs from the list passed to this
# function as the third argument.
#
func.getGpuString ( )
{
    if [ $# -ne 3 ]; then 
        echo "ERROR: func.getGpuString needs #GPUs as 1st, #MPI as 2nd, and"
        echo "       a string with allowed GPU IDs as 3rd argument (all per node)!" >&2
        echo "       It got: '$@'" >&2
        exit 333
    fi

    # number of GPUs per node:
    local NGPU=$1
    # number of PP ranks per node:
    local N_PP=$2
    # string with the allowed GPU IDs to use:
    local ALLOWED=$3

    local currGPU=0
    local nextGPU=1
    local iPP
    # loop over all PP ranks on a node:
    for ((iPP=0; iPP < $N_PP; iPP++)); do
        local currGpuId=${ALLOWED:$currGPU:1} # single char starting at pos $currGPU
        local nextGpuId=${ALLOWED:$nextGPU:1} # single char starting at pos $nextGPU

        # append this GPU's ID to the GPU string:
        local GPUSTRING=${GPUSTRING}${currGpuId}

        # check which GPU ID the _next_ MPI rank should use:
        local NUM=$( echo "($iPP + 1) * $NGPU / $N_PP" | bc -l )
        local COND=$( echo "$NUM >= $nextGPU" | bc )
        if [ "$COND" -eq "1" ] ; then
            ((currGPU++))
            ((nextGPU++))
        fi
    done
    
    # return the constructed string:
}
#==============================================================================



#==============================================================================
# Do the benchmarks!
#==============================================================================
# 1 generate DIR
DIR=$( pwd )
DIRCOUNT=0
mkdir "$DIR"/$TPRDIR
cp $TPR  "$DIR"/$TPRDIR
for NTMPI in $RANKLIST ; do  # list with all numbers of thread-MPI ranks to use
    NTOMPMAX=$( echo "$CORES / $NTMPI" | bc )
    if [[ $ALLTHREAD -eq 1 ]];then
        THREADLIST=$NTOMPMAX
    fi
    #for NGPU in $NGPU_PER_HOST; do
        #GPUSTR=$( func.getGpuString $NGPU $NTMPI $USEGPUIDS )
    for GPUSTR in $GPUID; do
        if [[ "$NTMPI" -eq 1 && "${#GPUSTR}" -gt 1 ]];then
            continue
        fi
        if [[ "$GPUSTR" == "None" ]]; then
            GPUCOM=""
        else
            GPUCOM="-gpu_id $GPUSTR"
        fi
        for gt in $GPUTASK; do
            case $gt in
                0) GPUFLAG='-nb cpu -pme cpu -bonded cpu';;
                1) GPUFLAG='-nb gpu -pme cpu -bonded cpu';;
                2) if [ $NTMPI -eq 1 ];then GPUFLAG='-nb gpu -pme gpu -bonded cpu'; else GPUFLAG='-nb gpu -pme gpu -bonded cpu -npme 1'; fi;;
                3) GPUFLAG='-nb gpu -pme cpu -bonded gpu';;
                4) if [ $NTMPI -eq 1 ];then GPUFLAG='-nb gpu -pme gpu -bonded gpu'; else GPUFLAG='-nb gpu -pme gpu -bonded gpu -npme 1'; fi;;
            esac
            for NTOMP in $THREADLIST; do
                if [[ $NTOMP -le $NTOMPMAX && $NTOMP -le 64 ]];then
                    MPI=$(printf "%02d" $NTMPI)
                    OMP=$(printf "%02d" $NTOMP)
                    RUN=ntmpi${MPI}_ntomp${OMP}_gpuid${GPUSTR}_gt${gt}
                    mkdir "$DIR"/$TPRDIR/run$RUN
                    cd "$DIR"/$TPRDIR/run$RUN
                    export GMX_NSTLIST=20
                    echo " $MDRUN -ntmpi $NTMPI -ntomp $NTOMP  -s "$DIR/$TPRDIR/$TPR" -cpt 1440 -nsteps $TOTALSTEP -resetstep $RESETSTEP -v -noconfout $GPUCOM $GPUFLAG $ADDOP" > run.sh
                    ((DIRCOUNT++))
                fi
            done
        done
    done
done

echo "$DIRCOUNT test file generate completed"
# check and run benchmark
for i in "$DIR"/$TPRDIR/run*;do
    echo $i
    cd $i
    flag=$(grep Finished md.log)
    if [ -z "$flag" ];then
        sh run.sh
    else
        echo $i" finished"
    fi
done
#extract and analysis
printf "%4s %4s %4s %8s %8s %9s %9s %9s %9s %9s\n" "#GPU" "#MPI" "#OMP" "GPUTASK" "ns/day" "WaitGPU_PME" "PME_MESH" "WaitGPU_NB" "Force" "Constraints" | tee $DIR/$TPRDIR-results.log
for i in "$DIR"/$TPRDIR/run*;do
   cd $i
   GTID="${i: -1}"
   FILENM=md.part0001.log
   if [ ! -f "$FILENM" ] ; then
       FILENM=md.log
   fi

   VERSION=`grep      'Gromacs version:'             $FILENM | awk '{ print $4 }'`
   CPUTYPE=`grep      'Brand:  '                     $FILENM | awk '{ print $2 " " $5 }'`
   GPUTYPE=`grep      ' #0: NVIDIA '                 $FILENM | cut -f 1 -d , |  awk '{ print $5 $6 }'`
   N_MPI__=`grep      ' MPI thread'                  $FILENM | awk '{ print $2 }'`
   if [ -z "$N_MPI__" ]; then
       N_MPI__=`grep 'MPI processes'                 $FILENM | grep "Using" | awk '{ print $2 }'`
   fi
   N_OMP__=`grep      'Using [0-9]* OpenMP threads '              $FILENM | awk '{ print $2 }'`
   if [ -z "$N_OMP__" ]; then
       N_OMP__=1
   fi
   N_GPU__=`grep      '-selected for this run'       $FILENM | awk '{if ($1=="On") print $4;else print $1 }'`
   NANOSPD=`grep      'Performance'                  $FILENM | awk '{ print $2 }'`
#   NEIGHBS=`grep      'Neighbor search'              $FILENM | awk '{ print $8 }'`
#   NSTLIST=`grep      'nstlist  '                    $FILENM | awk '{ print $3 }'`
#   ACCELER=`grep      'Acceleration most likely'     $FILENM | awk '{ print $8 }'`
#   BRAND__=`grep      'Brand: '                      $FILENM | awk '{ print $3$5 }'`
#   PMENODE=`grep      ', separate PME nodes'         $FILENM | awk '{ print $NF }'`
#                   R_COUL_=`grep      '   optimal pme grid '         $FILENM | awk '{ print $9 }'`
#   R_COUL_=`grep      '   final   '                  $FILENM | awk '{ print $2 }'`
   WG_PME_=`grep      'Wait PME GPU gather'          $FILENM | awk '{ printf "%6.2f(%3.1f)",$8,$10 }'`
   if [ -z "$WG_PME_" ];then
       WG_PME_=NaN
   fi
   WG_NB__=`grep      'Wait GPU NB local'            $FILENM | awk '{ printf "%6.2f(%3.1f)",$8,$10 }'`
   if [ -z "$WG_NB__" ];then
       WG_NB__=NaN
   fi
   FORCE__=`grep      ' Force '                      $FILENM | awk '{ printf "%6.2f(%3.1f)",$5,$7 }'`
   CONSTRS=`grep      ' Constraints '                $FILENM | awk '{ printf "%6.2f(%3.1f)",$5,$7 }'`
   PME_MESH=`grep     ' PME mesh   '                   $FILENM | awk '{ printf "%6.2f(%3.1f)",$6,$8 }'`
   if [ -z "$PME_MESH" ];then
       PME_MESH=NaN
   fi
   #DOMDEC_=`grep      'Domain decomposition grid '   $FILENM | cut -d , -f 1 | awk '{ print $4 " " $6 " " $8 }'`
   #if [ "$N_MPI__" == "1" ] ; then
   #    DOMDEC_="1 1 1"
   #fi
    printf "%4d %4d %4d %8d %8.3f %9s %9s %9s %9s %9s\n" "${N_GPU__}" "${N_MPI__}" "${N_OMP__}" "${GTID}" "$NANOSPD" "$WG_PME_" "$PME_MESH" "$WG_NB__" "$FORCE__" "$CONSTRS" | tee -a $DIR/$TPRDIR-results.log
done

