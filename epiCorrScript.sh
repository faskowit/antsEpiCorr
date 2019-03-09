#!/bin/bash
#
# epi correct
#
#
#

###############################################################################
# env stuff

shopt -s nullglob # No-match globbing expands to null

# make sure ANTSPATH and FSLDIR are defined
if [[ -z ${ANTSPATH} ]] ; then
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

    while (( $# > 1 )) ; do
        case "$1" in
            "-help")
                Usage
                ;;
            -d) shift ; DWI="${1}" ; shift
                ;;
            -b) shift ; BVAL="${1}" ; shift
                ;;
            -r) shift ; BVEC="${1}" ; shift
                ;;
            -m) shift ; MASK="${1}" ; shift
                ;;
            -o) shift ; ODIR="${1}" ; shift
                ;;
            -t) shift ; T1WDWISPACE="${1}" ; shift
                ;;
            -a) shift ; APPLYWARP="true"
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
            -z {ODIR} || -z ${T1W} || -z ${MASK} ]]
    then
        echo "not enough arguments"
        Usage
    fi

    ###########################################################################
    # run it

    start=`date +%s`

    # make a b0
    cmd="${FSLDIR}/bin/select_dwi_vols \
            ${DWI} \
            ${BVAL} \
            ${ODIR}/avgb0.nii.gz \
            -m -b 0 \
        "
    log ${cmd}
    eval ${cmd}

    cmd="${ANTSPATH}/ImageMath 3 \
            ${ODIR}/avgb0.nii.gz \
            Sharpen ${ODIR}/avgb0.nii.gz \
        "
    log ${cmd}
    eval ${cmd}

    # skull strip again
    cmd="${FSLDIR}/bin/bet2 \
            ${ODIR}/avgb0.nii.gz \
            ${ODIR}/mask \
            -m -f 0.2 \
        "
    log ${cmd}
    eval ${cmd}

    ###########################################################################
    # make power map

    # make the anisotropic power
    cmd="python ${EXEDIR}/dipyPowMap.py \
            -dwi ${DWI} \
            -bval ${BVAL} \
            -bvec ${BVEC} \
            -mask ${ODIR}/mask_mask.nii.gz \
            -output ${ODIR}/map
            -sh_order ${DEFpowersh} \
            -make_power_map \
        "
    log ${cmd}
    eval ${cmd}

    powMap=${ODIR}/map_powMap_sh${DEFpowersh}.nii.gz

    ###########################################################################
    # run the registration

    cmd="${ANTSPATH}/antsRegistration \
            -d 3 -v 1 \
            --output [${ODIR}/${subj}_epi_,${ODIR}/defb0.nii.gz] \
            --write-composite-transform 0 \
            \
            --metric MI[${T1WDWISPACE},${ODIR}/mask.nii.gz,0.25, 32] \
            --metric CC[${T1WDWISPACE},${powMap},0.75, 4] \
                --transform SyN[0.1,3.0,1] \
                --convergence [50x40x20,1e-6,5] \
                --shrink-factors 1x1x1 \
                --smoothing-sigmas 1x0.5x0 \
                --use-histogram-matching 0 \
                -g 0.01x1x0.01 \
            \
            --metric MI[${T1WDWISPACE},${ODIR}/mask.nii.gz,0.5, 32] \
            --metric CC[${T1WDWISPACE},${powMap},0.5, 4] \
                --transform SyN[0.15,3.0,0.25] \
                --convergence [10x10,1e-6,5] \
                --shrink-factors 1x1 \
                --smoothing-sigmas 0.5x0 \
                --use-histogram-matching 0 \
                -g 0.01x1x0.01 \
        "
    log ${cmd}
    eval ${cmd}

    end=`date +%s`
    runtime=$((end-start))
    echo "runtime: $runtime"
    log "runtime: $runtime" >> $OUT

    ###########################################################################
    # also apply the warp?

    if [[ ${APPLYWARP} = "true" ]] ; then

        warp=${ODIR}/${subj}_epi_0Warp.nii.gz

        cmd="${ANTSPATH}/antsApplyTransforms \
                -d 3 -v 1 \
                -e 3 \
                -i ${DWI} \
                -r ${ODIR}/avgb0.nii.gz \
                -n BSpline \
                -o ${workingDir}/dwi_antsEpiCorr.nii.gz \
                --float \
                -t ${warp} \
            "
        log ${cmd}
        eval ${cmd}

    fi

}

###############################################################################
# call to main with the bash cmd line input args
main "$@"
