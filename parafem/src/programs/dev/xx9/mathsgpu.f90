MODULE MATHSGPU

  !/****h* /mathsgpu
  !*  NAME
  !*    MODULE: mathsgpu
  !*  SYNOPSIS
  !*    Usage:      USE mathsgpu
  !*  FUNCTION
  !*    Contains subroutines required for standard mathematical operations on
  !*    matrices and vectors. These subroutines are parallel and require MPI.
  !*    
  !*    Subroutine             Purpose
  !*
  !*  AUTHOR
  !*    L. Margetts
  !*  COPYRIGHT
  !*    2021 University of Manchester
  !******
  !*  Place remarks that should not be included in the documentation here.
  !*
  !*/

  USE mpi_wrapper
  USE precision
  USE mp_interface
  USE gather_scatter
  USE maths

  CONTAINS

!------------------------------------------------------------------------------
!------------------------------------------------------------------------------
!------------------------------------------------------------------------------

  SUBROUTINE PCG_KM_GPU(diag_precon_pp,km,limit,nels_pp,r_pp,                  &
                        timest,tol,xnew_pp,iters)

  !/****f* maths/pcg_km_gpu
  !*  NAME
  !*    SUBROUTINE: pcg_km_gpu
  !*  SYNOPSIS
  !*    Usage:      CALL pcg_km_gpu(limit,tol,km,diag_precon_pp,timest,     &
  !*                            xnew_pp,iters)
  !*  FUNCTION
  !*    Iterative solver (PCG) to solve a linear system of equations
  !*    Assumes all elements have the identical stiffness matrix KM
  !*    GPU version
  !*  INPUTS
  !*    The following arguments have the INTENT(IN) attribute:
  !*
  !*    limit                    : Integer
  !*                             : Maximum number of PCG iterations allowed
  !*
  !*    nels_pp                  : Integer
  !*                             : Elements per cpu (or MPI process)
  !*
  !*    tol                      : Real
  !*                             : Tolerance for PCG
  !*
  !*    km(ntot,ntot)            : Real
  !*                             : Element stiffness matrix
  !*
  !*    diag_precon_pp(neq_pp)   : Real
  !*                             : Inverse of diagonal preconditioner
  !*
  !*    The following arguments have the INTENT(INOUT) attribute:
  !*
  !*    xnew_pp(neq_pp)          : Real
  !*                             : Solution of the system of equations
  !*
  !*    timest(:)                : Real
  !*                             : Timing information
  !*
  !*    The following arguments have the INTENT(OUT) attribute:
  !*
  !*    iters                    : Integer
  !*                             : Number of PCG iterations
  !*
  !*  AUTHOR
  !*    Lee Margetts
  !*  CREATION DATE
  !*    08.05.2021
  !*  COPYRIGHT
  !*    (c) University of Manchester 2021
  !******
  !*  Place remarks that should not be included in the documentation here.
  !*
  !*  The solution scheme is based on x = 0.0 as starting guess and 
  !*  is as follows:
  !*
  !*  r = b - A*x  (r = b  if x = 0.0 as starting guess)
  !*  d = Minv*r
  !*  delta_new = r*d
  !*  iters = 0
  !*  WHILE (iters<limit and sqrt(rn/rn0) < tol) DO
  !*    iters = iters + 1
  !*    q = A*d
  !*    alpha = delta_new/(d*q)
  !*    x = x + alpha*d
  !*    r = r - alpha*q
  !*    s = Minv*r
  !*    delta_old = delta_new
  !*    delta_new = r*s
  !*    beta = delta_new/delta_old
  !*    d = s + beta*d
  !*  END DO  
  !* 
  !*/

  USE timing
  USE iso_c_binding

  IMPLICIT NONE

  INTEGER,   INTENT(IN)    :: limit
  INTEGER,   INTENT(IN)    :: nels_pp
  REAL(iwp), INTENT(IN)    :: tol, km(:,:), diag_precon_pp(:)
  REAL(iwp), INTENT(INOUT) :: xnew_pp(:)
  REAL(iwp), INTENT(INOUT) :: timest(:)
  INTEGER,   INTENT(OUT)   :: iters
  LOGICAL                  :: converged=.FALSE.
  INTEGER                  :: neq_pp, ntot, iel
  REAL(iwp)                :: alpha, beta, up0, up1 
  REAL(iwp)                :: local_dot, global_dot
  REAL(iwp)                :: t_start1, t_start2, t_rawcomp, t_comp
  REAL(iwp), PARAMETER     :: zero=0.0_iwp
  REAL(iwp), ALLOCATABLE   :: p_pp(:), pmul_pp(:,:), utemp_pp(:,:),           &
                              u_pp(:), x_pp(:), d_pp(:), r_pp(:)

!------------------------------------------------------------------------------
! 1. GPU related variables
!------------------------------------------------------------------------------

  INTEGER :: cublas_alloc, cublas_free
  INTEGER :: cublas_set_matrix, cublas_get_matrix
  INTEGER :: cublas_set_vector
  INTEGER :: cublas_get_vector
  INTEGER :: cublas_init, cublas_shutdown

  INTEGER :: status
! INTEGER :: ndof_per_element
  INTEGER(KIND=c_size_t) :: device_matrix
  INTEGER(KIND=c_size_t) :: device_lhs_vectors
  INTEGER(KIND=c_size_t) :: device_rhs_vectors
  INTEGER(KIND=c_size_t) :: device_p_pp
  INTEGER(KIND=c_size_t) :: device_u_pp
  INTEGER(KIND=c_size_t) :: device_r_pp
  INTEGER(KIND=c_size_t) :: device_diag_precon_pp
  INTEGER(KIND=c_size_t) :: device_d_pp
 
! LOGICAL :: use_gpu = .false.
  CHARACTER(LEN=20, KIND=c_char) :: op
  CHARACTER(LEN=20, KIND=c_char) :: op2

  REAL(iwp) :: cublas_Ddot
  
!  REAL(iwp) :: t_rawcomp
!  REAL(iwp) :: t_comp
!  REAL(iwp) :: t_start1
!  REAL(iwp) :: t_start2
!  !Timer function
!  integer :: m, n, ans
!  real :: startT, endT, execTime

!------------------------------------------------------------------------------
! 2. Interface to function to set device
!------------------------------------------------------------------------------
  
  INTERFACE

     INTEGER(c_int) FUNCTION set_gpu(device_id) bind(C)
       
       USE iso_c_binding
       
       INTEGER(c_int) :: device_id
     END FUNCTION set_gpu
     
     INTEGER(c_int) FUNCTION sync_gpu() bind(C)
       USE iso_c_binding
     END FUNCTION sync_gpu

  END INTERFACE

!-----------------------------------------------------------------------
! 3. Allocate internal arrays
!-----------------------------------------------------------------------

    neq_pp   = UBOUND(r_pp,1)
    ntot     = UBOUND(km,1)

    ALLOCATE (p_pp(neq_pp), pmul_pp(ntot,nels_pp), utemp_pp(ntot,nels_pp), &
              u_pp(neq_pp), x_pp(neq_pp), d_pp(neq_pp))

    p_pp     = zero
    pmul_pp  = zero
    utemp_pp = zero
    u_pp     = zero
    x_pp     = zero
    d_pp     = zero

!-----------------------------------------------------------------------
! 4. Set up the GPU
!-----------------------------------------------------------------------
     
    if (.false.) then
        status = set_gpu(numpe-1)
        if (status > 0) then
           print *, "GPU memory failed to allocate!"
           stop
        end if
    end if

  ! Initialize CUBLAS
    status = cublas_init
    if (status .ne. 0) then
        print *, "GPU failed to initialise!"
        status = cublas_shutdown
        stop
    end if

  ! Allocate memory on the gpu for km
    status = cublas_alloc( &
          ntot**2,         &
          sizeof(0.0d0),   &
          device_matrix)
    if (status .ne. 0) then
        print *, "GPU memory failed to allocate!"
        status = cublas_shutdown
        stop
    end if

  ! Allocate memory for matrix of lhs vectors
    status = cublas_alloc( &
          nels_pp*ntot,    &
          sizeof(0.0d0),   &
          device_lhs_vectors)
    if (status .ne. 0) then
        print *, "GPU memory failed to allocate!"
        status = cublas_shutdown
        stop
    end if

  ! Allocate memory for matrix of rhs vectors
    status =  cublas_alloc( &
          nels_pp*ntot,     &
          sizeof(0.0d0),    &
          device_rhs_vectors)
    if (status .ne. 0) then
        print *, "GPU memory failed to allocate!"
        status = cublas_shutdown
        stop
    end if
     
  ! Allocate memory for p_pp and u_pp on GPU
    status = cublas_alloc( &
          neq_pp,          &
!         nels_pp*ntot,    &
          sizeof(0.0d0),   &
          device_p_pp)
    if (status .ne. 0) then 
        print *,"GPU memory failed to allocate p_pp!"
        status = cublas_shutdown
        stop
    end if   

    status = cublas_alloc( &
          neq_pp,          &
!         nels_pp*ntot,    &
          sizeof(0.0d0),   &
          device_u_pp)
    if (status .ne. 0) then
        print *, "GPU memory failed to allocate u_pp!"
        status = cublas_shutdown
        stop
    end if

    status = cublas_alloc( &
          neq_pp,          &
          sizeof(0.0d0),   &
          device_r_pp)
    if (status .ne. 0) then
        print *, "GPU memory failed to allocate r_pp!"
        status = cublas_shutdown
        stop
    end if

    status = cublas_alloc( &
          neq_pp,          &
          sizeof(0.0d0),   &
          device_diag_precon_pp)
    if (status .ne. 0) then
        print *, "GPU memory failed to allocate diag_precon_pp!"
        status = cublas_shutdown
        stop
    end if

    status = cublas_alloc( &
          neq_pp,          &
          sizeof(0.0d0),   &
          device_d_pp)
    if (status .ne. 0) then
        print *, "GPU memory failed to allocate diag_precon_pp!"
        status = cublas_shutdown
        stop
    end if

  ! Copy km to the gpu
    status = cublas_set_matrix( &
          ntot,                 &
          ntot,                 &
          sizeof(0.0d0),        &
          km,                   &
          ntot,                 &
          device_matrix,        &
          ntot)
     if (status .ne. 0) then
        print *, "Failed to copy km to gpu!"
        status = cublas_shutdown
        stop
     end if

  ! Copy diag_precon_pp to the gpu
  status = cublas_set_vector(     &
           neq_pp,                &
           sizeof(0.d0),          &
           diag_precon_pp,        &
           1,                     &
           device_diag_precon_pp, &
           1)

!-------------------------------------------------------------------------------
! 5. Initialise scalars and arrays
!-------------------------------------------------------------------------------

  d_pp      = diag_precon_pp * r_pp 
  p_pp      = d_pp
  up0       = DOT_PRODUCT_P(r_pp,d_pp)

  status = cublas_set_vector( &
             neq_pp, &
             sizeof(0.d0), &
             r_pp, &
             1, &
             device_r_pp, &
             1)

  iters     = 0
  converged = .FALSE.

!-------------------------------------------------------------------------------
! 6. PCG algorithm
!-------------------------------------------------------------------------------

  iterations  :  DO

    iters    = iters + 1
    u_pp     = zero
    pmul_pp  = zero
    utemp_pp = zero

    IF(iters>1) THEN 
      status = cublas_get_vector( &
               neq_pp, &
               sizeof(0.d0), &
               device_p_pp, &
               1, &
               p_pp, &
               1)
      if (status .ne. 0) then
        print *, "Failed to copy device_p_pp to host!"
        status = cublas_shutdown
        stop
      end if
    END IF

    CALL GATHER(p_pp,pmul_pp)

    t_start1 = elap_time()

    ! Copy lhs vectors to gpu
    status = cublas_set_matrix( &
             ntot, &
             nels_pp, &
             sizeof(0.0d0), &
             pmul_pp, &
             ntot, &
             device_lhs_vectors, &
             ntot)
    if (status .ne. 0) then
        print *, "Failed to copy device_lhs_vectors to gpu!"
        status = cublas_shutdown
        stop
    end if

    t_start2 = elap_time()

    alpha = 1.d0
    beta = 0.d0
    op = "N"
    call cublas_dgemm( &
            trim(op)//c_null_char, &
            trim(op)//c_null_char, &
            ntot, &
            nels_pp, &
            ntot, &
            alpha, &
            device_matrix, &
            ntot, &
            device_lhs_vectors, &
            ntot, &
            beta, &
            device_rhs_vectors, &
            ntot)

       ! Set to true to measure raw kernel execution time
    if (.true.) then

        status = sync_gpu()
        if (status .ne. 0) then
           print *, "Failed to sync gpu!"
           status = cublas_shutdown
           stop
        end if
    end if

    t_rawcomp = t_rawcomp + (elap_time() - t_start2)    

    ! Copy result vectors back from gpu
    status = cublas_get_matrix( &
             ntot, & 
             nels_pp, &
             sizeof(0.0d0), &
             device_rhs_vectors, &
             ntot, & 
             utemp_pp, &
             ntot)
    if (status .ne. 0) then
        print *, "Failed to copy data from gpu!"
        status = cublas_shutdown
        stop
    end if

    t_comp = t_comp + (elap_time() - t_start1)     

    CALL SCATTER(u_pp,utemp_pp)

    timest(17) = elap_time()

    status = cublas_set_vector( &
             neq_pp, &
             sizeof(0.d0), &
             p_pp, &
             1, &
             device_p_pp, &
             1)
    if (status .ne. 0) then
        print *, "Failed to copy p_pp to gpu!"
        status = cublas_shutdown
        stop
    end if

    status = cublas_set_vector( &
             neq_pp, &
             sizeof(0.d0), &
             u_pp, &
             1, &
             device_u_pp, &
             1)                                 
    if (status .ne. 0) then
        print *, "Failed to copy u_pp to gpu!"
        status = cublas_shutdown
        stop
    end if
 
    timest(18) = timest(18) + (elap_time()-timest(17))

    timest(19) = elap_time()

    local_dot = cublas_Ddot(neq_pp,device_p_pp,1,device_u_pp,1)

    timest(20) = timest(20) + (elap_time()-timest(19))

    bufsize=1
    CALL MPI_ALLREDUCE(local_dot,global_dot,bufsize,MPI_REAL8,MPI_SUM,      &
                       MPI_COMM_WORLD,ier)

    alpha   = up0/global_dot
    xnew_pp = x_pp + p_pp*alpha

!------------------------------------------------------------------------------
 
!   r_pp    = r_pp - u_pp*alpha

    alpha = alpha * (-1.0_iwp)
    call cublas_daxpy(neq_pp,alpha,device_u_pp,1,device_r_pp,1)

!------------------------------------------------------------------------------

!   d_pp    = diag_precon_pp*r_pp

    alpha = 1.d0
    beta  = 0.d0
    op2   = "U"

    call cublas_dsbmv( &
            trim(op2)//c_null_char, &
            neq_pp, &
            0,    &
            alpha, &
            device_diag_precon_pp, &
            1, &
            device_r_pp, &
            1, &
            beta, &
            device_d_pp, &
            1)

!   up1     = DOT_PRODUCT_P(r_pp,d_pp)
    local_dot = cublas_Ddot(neq_pp,device_r_pp,1,device_d_pp,1)
    bufsize=1
    CALL MPI_ALLREDUCE(local_dot,up1,bufsize,MPI_REAL8,MPI_SUM,                &
                       MPI_COMM_WORLD,ier)

    beta    = up1/up0
    up0     = up1 

!   p_pp    = d_pp + p_pp*beta
!   Need to split original line of code into two CuBLAS calls

!   p_pp    = p_pp*beta
    call cublas_Dscal(neq_pp,beta,device_p_pp,1)

!   p_pp   = p_pp + d_pp*alpha
    alpha = 1.0_iwp
    call cublas_daxpy(neq_pp,alpha,device_d_pp,1,device_p_pp,1)

!-------------------------------------------------------------------------------
! 6.1 Check convergence. Master process reports results
!-------------------------------------------------------------------------------

    CALL checon_par(xnew_pp,tol,converged,x_pp)
    IF (converged .OR. iters==limit) EXIT

  END DO iterations

!------------------------------------------------------------------------------
! 7. Deallocate local arrays
!------------------------------------------------------------------------------

  DEALLOCATE (p_pp, pmul_pp, utemp_pp, u_pp, x_pp, d_pp)

!------------------------------------------------------------------------------
! 8. GPU clean up
!------------------------------------------------------------------------------
  
  status = cublas_free(device_matrix)
  status = cublas_free(device_lhs_vectors)
  status = cublas_free(device_rhs_vectors)
  status = cublas_free(device_matrix)
  status = cublas_free(device_r_pp)
  status = cublas_free(device_u_pp)
  status = cublas_free(device_p_pp)
  status = cublas_free(device_p_pp)
  status = cublas_free(device_diag_precon_pp)
  status = cublas_shutdown

  timest(15) = t_rawcomp
  timest(16) = t_comp

  RETURN

  END SUBROUTINE PCG_KM_GPU

!------------------------------------------------------------------------------
!------------------------------------------------------------------------------
!------------------------------------------------------------------------------
  
END MODULE MATHSGPU
