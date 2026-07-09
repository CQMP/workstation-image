# workstation-image

Images for Warsaw workstations.

The image exports each workstation's local `/data` scratch disk to the
`10.42.1.0/24` workstation subnet and uses autofs to mount peer scratch disks
under `/shared_data/<host>`, for example `/shared_data/matsubara` and
`/shared_data/hubbard`.
