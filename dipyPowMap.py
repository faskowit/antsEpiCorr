__author__ = 'jfaskowitz'

"""
Josh Faskowitz
Indiana University

inspiration taken from the dipy website
and from this gist:
https://gist.github.com/mpaquette/c785bb4d584297f1d8112c0725f69fbe
"""

import os
import sys
import argparse
import numpy as np
import nibabel as nib


def isfloat(value):
    try:
        float(value)
        return True
    except ValueError:
        return False


def isint(value):
    try:
        int(value)
        return True
    except ValueError:
        return False


def printfl(istr):
    print(str(istr))
    sys.stdout.flush()


def checkisfile(fname):
    if not os.path.isfile(fname):
        print('files does not exist: {}\nexiting'.format(fname))
        exit(1)


class readArgs:

    def __init__(self):
        self.dwi_ = self.mask_ = self.bvec_ = self.bval_ = self.output_ = ''
        self.sh_order_ = 4

    @staticmethod
    def collect_args():
        argparse_obj = argparse.ArgumentParser(description="make power map")
        # this is the whole dwi with all the volumes yo
        argparse_obj.add_argument('-dwi', type=str, nargs=1, required=True,
                                 help="Path to dwi")
        argparse_obj.add_argument('-mask', type=str, nargs=1, required=True,
                                 help="Path to mask, in dwi space")
        argparse_obj.add_argument('-bvec', type=str, nargs=1, required=True,
                                 help="Path to bvec file (dipy likes bvecs to be unit vectors)")
        argparse_obj.add_argument('-bval', type=str, nargs=1, required=True,
                                 help="Path to bvals")
        argparse_obj.add_argument('-output', type=str, nargs=1, required=True,
                                 help="Output prefix path")
        argparse_obj.add_argument('-sh_order', type=int, nargs=1, required=False, choices=range(2, 14, 2),
                                 help="sh order ofr signal modeling. default 4")
        return argparse_obj

    def check_args(self, args_to_check):
        args = args_to_check.parse_args()
        self.dwi_ = args.dwi
        self.mask_ = args.mask
        self.bvec_ = args.bvec
        self.bval_ = args.bval
        self.output_ = args.output
        if args.sh_order:
            self.sh_order_ = args.sh_order
        checkisfile(self.dwi_)
        checkisfile(self.mask_)
        checkisfile(self.bvec_)
        checkisfile(self.bval_)
        if args.sh_order and not isint(self.sh_order_):
            print("sh needs to be an in yo... probs 2 or 4 or 6 or 8")
            exit(1)


def main():
    params = readArgs()
    # read in from the command line
    read_args = params.collect_args()
    params.check_args(read_args)

    # get img obj
    dwi_img = nib.load(params.dwi_)
    mask_img = nib.load(params.mask_)

    from dipy.io import read_bvals_bvecs
    bvals, bvecs = read_bvals_bvecs(params.bval_,
                                    params.bvec_)

    # need to create the gradient table yo
    from dipy.core.gradients import gradient_table
    gtab = gradient_table(bvals, bvecs, b0_threshold=25)

    # get the data from image objects
    dwi_data = dwi_img.get_data()
    mask_data = mask_img.get_data()
    # and get affine
    img_affine = mask_img.affine

    from dipy.data import get_sphere
    sphere = get_sphere('repulsion724')

    from dipy.segment.mask import applymask
    dwi_data = applymask(dwi_data, mask_data)

    printfl('dwi_data.shape (%d, %d, %d, %d)' % dwi_data.shape)
    printfl('\nYour bvecs look like this:{0}'.format(bvecs))
    printfl('\nYour bvals look like this:{0}\n'.format(bvals))

    from dipy.reconst.shm import anisotropic_power, sph_harm_lookup, smooth_pinv, normalize_data
    from dipy.core.sphere import HemiSphere

    smooth = 0.0
    normed_data = normalize_data(dwi_data, gtab.b0s_mask)
    normed_data = normed_data[..., np.where(1 - gtab.b0s_mask)[0]]

    from dipy.core.gradients import gradient_table_from_bvals_bvecs
    gtab2 = gradient_table_from_bvals_bvecs(gtab.bvals[np.where(1 - gtab.b0s_mask)[0]],
                                            gtab.bvecs[np.where(1 - gtab.b0s_mask)[0]])

    signal_native_pts = HemiSphere(xyz=gtab2.bvecs)
    sph_harm_basis = sph_harm_lookup.get(None)
    Ba, m, n = sph_harm_basis(params.sh_order_,
                              signal_native_pts.theta,
                              signal_native_pts.phi)

    L = -n * (n + 1)
    invB = smooth_pinv(Ba, np.sqrt(smooth) * L)

    # fit SH basis to DWI signal
    normed_data_sh = np.dot(normed_data, invB.T)

    # power map call
    printfl("fitting power map")
    pow_map = anisotropic_power(normed_data_sh,
                                norm_factor=0.00001,
                                power=2,
                                non_negative=True)

    pow_map_img = nib.Nifti1Image(pow_map.astype(np.float32), img_affine)
    # make output name
    out_name = ''.join([params.output_, '_powMap_sh', str(params.sh_order_), '.nii.gz'])

    printfl("writing power map to: {}".format(out_name))
    nib.save(pow_map_img, out_name)


if __name__ == '__main__':
    main()
