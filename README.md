# workstation-image

Images for Warsaw workstations.

The image mounts `/data` from `luttinger-storage` over NFSv4.2. It exports each
workstation's local `/scratch` disk to the `10.42.1.0/24` workstation subnet
and uses autofs to mount peer scratch disks under `/shared_scratch/<host>`,
for example `/shared_scratch/matsubara` and `/shared_scratch/hubbard`.
