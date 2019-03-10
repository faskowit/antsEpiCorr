#!/bin/bash
#
# epi correct w/ ANTs registration to T1w
# the registation uses both the avg B0 and the dwi power map to register the 
# dwi to the T1. the power map has similar contrast to the T1. if you'd like
# to see the power map, just comment out the line at the end of main that 
# removes the file
#
# Josh Faskowitz
# Indiana University
#

###############################################################################
# env stuff

shopt -s nullglob # No-match globbing expands to null

# make sure ANTSPATH and FSLDIR are defined
if [[ -z ${ANTSPATH} ]] ; then
    echo "$ANTSPATH"
    echo "please make sure ANTSPATH is defined"
    exit 1
fi
if [[ -z ${FSLDIR} ]] ; then
    echo "please make sure FSLDIR is defined"
    exit 1
fi

EXEDIR=$(dirname "$(readlink -f "$0")")/

###############################################################################
# funcs & globals

Usage() {
cat <<EOF
Usage: `basename $0`

    -d [file]   input dwi
    -b [file]   bvals (FSL style)
    -r [file]   bvecs (FSL style)
    -m [file]   dwi mask
    -o [path]   output base
    -t [file]   t1 in dwi space
    -a          (opt flag) apply the warp to dwi

EOF
exit
}

log() {
    local msg="$*"
    local dateTime=`date`
    echo "# "$dateTime "-" $log_toolName "-" "$msg"
    echo "$msg"
    echo
}

lsrm() {
    file=$1
    ls ${file} && rm $file
}

DEFpowersh=4
APPLYWARP="false"

###############################################################################
# main

main()
{

    echo "Registration based epi correction with ANTs"
    echo ""
    echo "NOTE: this script assumes phase encoding along the A-P axis. \
          If this is not the case, script needs to be edited"
    echo "" ; echo "" ;  echo ""

    ###########################################################################
    # parse arguments

    while (( $# > 0 )) ; do
        case "$1" in
            "-help")
                Usage
                ;;
            -d | -dwi) shift ; DWI="${1}" ; shift
                ;;
            -b | -bval) shift ; BVAL="${1}" ; shift
                ;;
            -r | -bvec) shift ; BVEC="${1}" ; shift
                ;;
            -m | -mask) shift ; MASK="${1}" ; shift
                ;;
            -o | -out) shift ; ODIR="${1}" ; shift
                ;;
            -t | -t1) shift ; T1WDWISPACE="${1}" ; shift
                ;;
            -a | -apply) shift ; APPLYWARP="true" 
                ;;
            -*)
                echo "ERROR: Unknown option '$1'"
                exit 1
                break
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ -z ${DWI} || -z ${BVAL} || -z ${BVEC} || \
            -z {ODIR} || -z ${T1WDWISPACE} || -z ${MASK} ]]
    then
        echo "not enough arguments"
        Usage
    fi

    ###########################################################################
    # run it

    start=`date +%s`
    mkdir -p ${ODIR} || { echo "cannot make output dir. exiting" ; exit 1 ; }

    # make a b0
    cmd="${FSLDIR}/bin/select_dwi_vols \
            ${DWI} \
            ${BVAL} \
            ${ODIR}/avgb0.nii.gz \
            0 -m \
        "
    log ${cmd}
    eval ${cmd}

    cmd="${FSLDIR}/bin/fslmaths \
            ${ODIR}/avgb0.nii.gz \
            -mas ${MASK} \
            ${ODIR}/avgb0.nii.gz \
        "
    log ${cmd}
    eval ${cmd}

    ###########################################################################
    # make power map

    # make the anisotropic power
    cmd="python3 ${EXEDIR}/dipyPowMap.py \
            -dwi ${DWI} \
            -bval ${BVAL} \
            -bvec ${BVEC} \
            -mask ${MASK} \
            -output ${ODIR}/map
            -sh_order ${DEFpowersh} \
        "
    log ${cmd}
    eval ${cmd}

    powMap=${ODIR}/map_powMap_sh${DEFpowersh}.nii.gz

    [[ ! -f ${powMap} ]] && { "power map not created. problem" ; exit 1 ; }

    cmd="${FSLDIR}/bin/fslmaths \
            ${powMap} \
            ${powMap} \
            -odt float \
        "
    log ${cmd}
    eval ${cmd}

    ###########################################################################
    # run the registration

    cmd="${ANTSPATH}/antsRegistration \
            -d 3 -v 1 \
            --output [ ${ODIR}/epi_ , ${ODIR}/defb0.nii.gz ] \
            --write-composite-transform 0 \
            \
            --metric MI[ ${T1WDWISPACE} , ${ODIR}/avgb0.nii.gz , 0.25 , 32 ] \
            --metric CC[ ${T1WDWISPACE} , ${powMap} , 0.75 , 4 ] \
                --transform SyN[ 0.1 , 3.0 , 1 ] \
                --convergence [ 50x40x20 , 1e-6 , 5 ] \
                --shrink-factors 1x1x1 \
                --smoothing-sigmas 1x0.5x0 \
                --use-histogram-matching 0 \
                -g 0.01x1x0.01 \
            \
            --metric MI[ ${T1WDWISPACE} , ${ODIR}/avgb0.nii.gz , 0.5 , 32 ] \
            --metric CC[ ${T1WDWISPACE} , ${powMap} , 0.5 , 4 ] \
                --transform SyN[ 0.15 , 3.0 , 0.25 ] \
                --convergence [ 10x10 , 1e-6 , 5 ] \
                --shrink-factors 1x1 \
                --smoothing-sigmas 0.5x0 \
                --use-histogram-matching 0 \
                -g 0.01x1x0.01 \
        "
    log ${cmd}
    eval ${cmd}

    warp=${ODIR}/epi_0Warp.nii.gz

    [[ ! -f ${warp} ]] && { "warp not created. problem" ; exit 1 ; }

    ###########################################################################
    # also apply the warp?

    if [[ ${APPLYWARP} = "true" ]] ; then

        if [[ -f ${warp} ]] ; then
            cmd="${ANTSPATH}/antsApplyTransforms \
                    -d 3 -v 1 -e 3 \
                    -i ${DWI} \
                    -r ${ODIR}/avgb0.nii.gz \
                    -n BSpline \
                    -o ${ODIR}/dwi_antsEpiCorr.nii.gz \
                    --float \
                    -t ${warp} \
                "
            log ${cmd}
            eval ${cmd}
        else
            # won't get here...
            echo "problem"
        fi
    fi

    end=`date +%s`
    runtime=$((end-start))
    echo "runtime: $runtime"

    # lets cleanup
    echo "removing intermediate files:"
    lsrm ${ODIR}/epi_0InverseWarp.nii.gz
    lsrm ${ODIR}/epi_0Warp.nii.gz
    lsrm ${ODIR}/map_powMap_sh4.nii.gz
}

###############################################################################
# call to main with the bash cmd line input args
main "$@"
