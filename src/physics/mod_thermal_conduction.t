!> Thermal conduction for HD and MHD
!> Adaptation of mod_thermal_conduction for the mod_supertimestepping
!> In order to use it set use_mhd_tc=1 (for the mhd impl) or 2 (for the hd impl) in mhd_list  (for the mhd module both hd and mhd impl can be used)
!> or use_new_hd_tc in hd_list parameters to true
!> (for the hd module, hd implementation has to be used)
!> The TC is set by calling one
!> tc_init_hd_for_total_energy and tc_init_mhd_for_total_energy might
!> The second argument: ixArray has to be [rho_,e_,mag(1)] for mhd (Be aware that the other components of the mag field are assumed consecutive) and [rho_,e_] for hd
!> additionally when internal energy equation is solved, an additional element of this array is eaux_: the index of the internal energy variable.
!>
!> 10.07.2011 developed by Chun Xia and Rony Keppens
!> 01.09.2012 moved to modules folder by Oliver Porth
!> 13.10.2013 optimized further by Chun Xia
!> 12.03.2014 implemented RKL2 super timestepping scheme to reduce iterations
!> and improve stability and accuracy up to second order in time by Chun Xia.
!> 23.08.2014 implemented saturation and perpendicular TC by Chun Xia
!> 12.01.2017 modulized by Chun Xia
!>
!> PURPOSE:
!> IN MHD ADD THE HEAT CONDUCTION SOURCE TO THE ENERGY EQUATION
!> S=DIV(KAPPA_i,j . GRAD_j T)
!> where KAPPA_i,j = tc_k_para b_i b_j + tc_k_perp (I - b_i b_j)
!> b_i b_j = B_i B_j / B**2, I is the unit matrix, and i, j= 1, 2, 3 for 3D
!> IN HD ADD THE HEAT CONDUCTION SOURCE TO THE ENERGY EQUATION
!> S=DIV(tc_k_para . GRAD T)
!> USAGE:
!> 1. in mod_usr.t -> subroutine usr_init(), add
!>        unit_length=your length unit
!>        unit_numberdensity=your number density unit
!>        unit_velocity=your velocity unit
!>        unit_temperature=your temperature unit
!>    before call (m)hd_activate()
!> 2. to switch on thermal conduction in the (m)hd_list of amrvac.par add:
!>    (m)hd_thermal_conduction=.true.
!> 3. in the tc_list of amrvac.par :
!>    tc_perpendicular=.true.  ! (default .false.) turn on thermal conduction perpendicular to magnetic field
!>    tc_saturate=.true.  ! (default .false. ) turn on thermal conduction saturate effect
!>    tc_slope_limiter='MC' ! choose limiter for slope-limited anisotropic thermal conduction in MHD

module mod_thermal_conduction
  use mod_global_parameters, only: std_len
  use mod_geometry
  use mod_comm_lib, only: mpistop
  implicit none

    !> The adiabatic index
    double precision :: tc_gamma_1

  abstract interface
    subroutine get_var_subr(w,x,ixI^L,ixO^L,res)
      use mod_global_parameters
      integer, intent(in)          :: ixI^L, ixO^L
      double precision, intent(in) :: w(ixI^S,nw)
      double precision, intent(in) :: x(ixI^S,1:ndim)
      double precision, intent(out):: res(ixI^S)
    end subroutine get_var_subr


  end interface

  type tc_fluid

    procedure (get_var_subr), pointer, nopass :: get_rho => null()
    procedure (get_var_subr), pointer, nopass :: get_rho_equi => null()
    procedure(get_var_subr), pointer,nopass :: get_temperature_from_eint => null()
    procedure(get_var_subr), pointer,nopass :: get_temperature_from_conserved => null()
    procedure(get_var_subr), pointer,nopass :: get_temperature_equi => null()
     !> Indices of the variables
    integer :: e_=-1
    !> Index of cut off temperature for TRAC
    integer :: Tcoff_
    ! if has_equi = .true. get_temperature_equi and get_rho_equi have to be set
    logical :: has_equi=.false.

    ! the following are read from param file or set in tc_read_hd_params or tc_read_mhd_params
    !> Coefficient of thermal conductivity (parallel to magnetic field)
    double precision :: tc_k_para

    !> Coefficient of thermal conductivity perpendicular to magnetic field
    double precision :: tc_k_perp

    !> Name of slope limiter for transverse component of thermal flux
    integer :: tc_slope_limiter

    !> Logical switch for test constant conductivity
    logical :: tc_constant=.false.

    !> Calculate thermal conduction perpendicular to magnetic field (.true.) or not (.false.)
    logical :: tc_perpendicular=.false.

    !> Consider thermal conduction saturation effect (.true.) or not (.false.)
    logical :: tc_saturate=.false.
    ! END the following are read from param file or set in tc_read_hd_params or tc_read_mhd_params
  end type tc_fluid


  public :: tc_get_mhd_params
  public :: tc_get_hd_params
  public :: get_tc_dt_mhd
  public :: get_tc_dt_hd
  public :: sts_set_source_tc_mhd
  public :: sts_set_source_tc_hd

contains

  subroutine tc_init_params(phys_gamma)
    use mod_global_parameters
    double precision, intent(in) :: phys_gamma

    tc_gamma_1=phys_gamma-1d0
  end subroutine tc_init_params

  !> Init  TC coeffiecients: MHD case
  subroutine tc_get_mhd_params(fl,read_mhd_params)
    use mod_global_parameters

    interface
      subroutine read_mhd_params(fl)
        use mod_global_parameters, only: unitpar,par_files
        import tc_fluid
        type(tc_fluid), intent(inout) :: fl

      end subroutine read_mhd_params
    end interface

    type(tc_fluid), intent(inout) :: fl

    fl%tc_slope_limiter=1

    fl%tc_k_para=0.d0

    fl%tc_k_perp=0.d0

    call read_mhd_params(fl)

    if(fl%tc_k_para==0.d0 .and. fl%tc_k_perp==0.d0) then
      if(SI_unit) then
        ! Spitzer thermal conductivity with SI units
        fl%tc_k_para=8.d-12*unit_temperature**3.5d0/unit_length/unit_density/unit_velocity**3
        ! thermal conductivity perpendicular to magnetic field
        fl%tc_k_perp=4.d-30*unit_numberdensity**2/unit_magneticfield**2/unit_temperature**3*fl%tc_k_para
      else
        ! Spitzer thermal conductivity with cgs units
        fl%tc_k_para=8.d-7*unit_temperature**3.5d0/unit_length/unit_density/unit_velocity**3
        ! thermal conductivity perpendicular to magnetic field
        fl%tc_k_perp=4.d-10*unit_numberdensity**2/unit_magneticfield**2/unit_temperature**3*fl%tc_k_para
      end if
      if(mype .eq. 0) print*, "Spitzer MHD: par: ",fl%tc_k_para, &
          " ,perp: ",fl%tc_k_perp
    else
      fl%tc_constant=.true.
    end if

    contains

    !> Read tc module parameters from par file: MHD case

  end subroutine tc_get_mhd_params

  subroutine tc_get_hd_params(fl,read_hd_params)
    use mod_global_parameters

    interface
      subroutine read_hd_params(fl)
        use mod_global_parameters, only: unitpar,par_files
        import tc_fluid
        type(tc_fluid), intent(inout) :: fl

      end subroutine read_hd_params
    end interface
    type(tc_fluid), intent(inout) :: fl

    fl%tc_k_para=0.d0
    !> Read tc parameters from par file: HD case
    call read_hd_params(fl)
    if(fl%tc_k_para==0.d0 ) then
      if(SI_unit) then
        ! Spitzer thermal conductivity with SI units
        fl%tc_k_para=8.d-12*unit_temperature**3.5d0/unit_length/unit_density/unit_velocity**3
      else
        ! Spitzer thermal conductivity with cgs units
        fl%tc_k_para=8.d-7*unit_temperature**3.5d0/unit_length/unit_density/unit_velocity**3
      end if
      if(mype .eq. 0) print*, "Spitzer HD par: ",fl%tc_k_para
    end if
  end subroutine tc_get_hd_params

  !> Get the explicut timestep for the TC (mhd implementation)
  function get_tc_dt_mhd(w,ixI^L,ixO^L,dx^D,x,fl) result(dtnew)
    !Check diffusion time limit dt < dx_i**2/((gamma-1)*tc_k_para_i/rho)
    !where                      tc_k_para_i=tc_k_para*B_i**2/B**2
    !and                        T=p/rho
    use mod_global_parameters

    type(tc_fluid), intent(in)  ::  fl
    integer, intent(in) :: ixI^L, ixO^L
    double precision, intent(in) :: dx^D, x(ixI^S,1:ndim)
    double precision, intent(in) :: w(ixI^S,1:nw)
    double precision :: dtnew

    double precision :: mf(ixO^S,1:ndim),Te(ixI^S),B2(ixI^S),gradT(ixI^S)
    double precision :: tmp2(ixO^S),tmp(ixO^S),hfs(ixO^S)
    double precision :: dtdiff_tcond,maxtmp2
    integer          :: idims

    !temperature
    call fl%get_temperature_from_conserved(w,x,ixI^L,ixI^L,Te)

    ! B
    if(B0field) then
      mf(ixO^S,1:ndim)=w(ixO^S,iw_mag(1:ndim))+block%B0(ixO^S,1:ndim,0)
    else
      mf(ixO^S,1:ndim)=w(ixO^S,iw_mag(1:ndim))
    end if
    ! B**2
    tmp=sum(mf**2,dim=ndim+1)
    ! B_i**2/B**2
    where(tmp(ixO^S)/=0.d0)
      ^D&mf(ixO^S,^D)=mf(ixO^S,^D)**2/tmp(ixO^S);
    elsewhere
      ^D&mf(ixO^S,^D)=1.d0;
    end where

    dtnew=bigdouble
    ! B2 is now density
    call fl%get_rho(w,x,ixI^L,ixO^L,B2)

    !tc_k_para_i
    if(fl%tc_constant) then
      tmp(ixO^S)=fl%tc_k_para
    else
      if(fl%tc_saturate) then
        ! Kannan 2016 MN 458, 410
        ! 3^1.5*kB^2/(4*sqrt(pi)*e^4)
        ! l_mfpe=3.d0**1.5d0*kB_cgs**2/(4.d0*sqrt(dpi)*e_cgs**4*37.d0)=7093.9239487765044d0
        tmp2(ixO^S)=Te(ixO^S)**2/B2(ixO^S)*7093.9239487765044d0*unit_temperature**2/(unit_numberdensity*unit_length)
        hfs=0.d0
        do idims=1,ndim
          call gradient(Te,ixI^L,ixO^L,idims,gradT)
          hfs(ixO^S)=hfs(ixO^S)+gradT(ixO^S)*sqrt(mf(ixO^S,idims))
        end do
        ! kappa=kappa_Spizer/(1+4.2*l_mfpe/(T/|gradT.b|))
        tmp(ixO^S)=fl%tc_k_para*dsqrt(Te(ixO^S)**5)/(1.d0+4.2d0*tmp2(ixO^S)*dabs(hfs(ixO^S))/Te(ixO^S))
      else
        ! kappa=kappa_Spizer
        tmp(ixO^S)=fl%tc_k_para*dsqrt(Te(ixO^S)**5)
      end if
    end if

    if(slab_uniform) then
      do idims=1,ndim
        ! approximate thermal conduction flux: tc_k_para_i/rho/dx*B_i**2/B**2
        tmp2(ixO^S)=tmp(ixO^S)*mf(ixO^S,idims)/(B2(ixO^S)*dxlevel(idims))
        maxtmp2=maxval(tmp2(ixO^S))
        ! dt< dx_idim**2/((gamma-1)*tc_k_para_i/rho*B_i**2/B**2)
        dtdiff_tcond=dxlevel(idims)/(tc_gamma_1*maxtmp2+smalldouble)
        ! limit the time step
        dtnew=min(dtnew,dtdiff_tcond)
      end do
    else
      do idims=1,ndim
        ! approximate thermal conduction flux: tc_k_para_i/rho/dx*B_i**2/B**2
        tmp2(ixO^S)=tmp(ixO^S)*mf(ixO^S,idims)/(B2(ixO^S)*block%ds(ixO^S,idims))
        maxtmp2=maxval(tmp2(ixO^S)/block%ds(ixO^S,idims))
        ! dt< dx_idim**2/((gamma-1)*tc_k_para_i/rho*B_i**2/B**2)
        dtdiff_tcond=1.d0/(tc_gamma_1*maxtmp2+smalldouble)
        ! limit the time step
        dtnew=min(dtnew,dtdiff_tcond)
      end do
    end if
    dtnew=dtnew/dble(ndim)

  end function get_tc_dt_mhd

  !> anisotropic thermal conduction with slope limited symmetric scheme
  !> Sharma 2007 Journal of Computational Physics 227, 123
  subroutine sts_set_source_tc_mhd(ixI^L,ixO^L,w,x,wres,fix_conserve_at_step,my_dt,igrid,nflux,fl)
    use mod_global_parameters
    use mod_fix_conserve
    integer, intent(in) :: ixI^L, ixO^L, igrid, nflux
    double precision, intent(in) ::  x(ixI^S,1:ndim)
    double precision, intent(in) ::   w(ixI^S,1:nw)
    double precision, intent(inout) ::  wres(ixI^S,1:nw)
    double precision, intent(in) :: my_dt
    logical, intent(in) :: fix_conserve_at_step
    type(tc_fluid), intent(in) :: fl

    !! qd store the heat conduction energy changing rate
    double precision :: qd(ixI^S)
    double precision :: rho(ixI^S),Te(ixI^S)
    double precision :: qvec(ixI^S,1:ndim)
    double precision, allocatable, dimension(:^D&,:) :: qvec_equi

    double precision, allocatable, dimension(:^D&,:,:) :: fluxall
    double precision :: alpha,dxinv(ndim)
    integer :: idims,idir,ix^D,ix^L,ixC^L,ixA^L,ixB^L

    ! coefficient of limiting on normal component
    if(ndim<3) then
      alpha=0.75d0
    else
      alpha=0.85d0
    end if
    ix^L=ixO^L^LADD1;

    dxinv=1.d0/dxlevel

    call fl%get_temperature_from_eint(w, x, ixI^L, ixI^L, Te)  !calculate Te in whole domain (+ghosts)
    call fl%get_rho(w, x, ixI^L, ixI^L, rho)  !calculate rho in whole domain (+ghosts)
    call set_source_tc_mhd(ixI^L,ixO^L,w,x,fl,qvec,rho,Te,alpha)
    if(fl%has_equi) then
      allocate(qvec_equi(ixI^S,1:ndim))
      call fl%get_temperature_equi(w, x, ixI^L, ixI^L, Te)  !calculate Te in whole domain (+ghosts)
      call fl%get_rho_equi(w, x, ixI^L, ixI^L, rho)  !calculate rho in whole domain (+ghosts)
      call set_source_tc_mhd(ixI^L,ixO^L,w,x,fl,qvec_equi,rho,Te,alpha)
      do idims=1,ndim
        qvec(ix^S,idims)=qvec(ix^S,idims) - qvec_equi(ix^S,idims)
      end do
      deallocate(qvec_equi)
    endif

    qd=0.d0
    if(slab_uniform) then
      do idims=1,ndim
        qvec(ix^S,idims)=dxinv(idims)*qvec(ix^S,idims)
        ixB^L=ixO^L-kr(idims,^D);
        qd(ixO^S)=qd(ixO^S)+qvec(ixO^S,idims)-qvec(ixB^S,idims)
      end do
    else
      do idims=1,ndim
        qvec(ix^S,idims)=qvec(ix^S,idims)*block%surfaceC(ix^S,idims)
        ixB^L=ixO^L-kr(idims,^D);
        qd(ixO^S)=qd(ixO^S)+qvec(ixO^S,idims)-qvec(ixB^S,idims)
      end do
      qd(ixO^S)=qd(ixO^S)/block%dvolume(ixO^S)
    end if

    if(fix_conserve_at_step) then
      allocate(fluxall(ixI^S,1,1:ndim))
      fluxall(ixI^S,1,1:ndim)=my_dt*qvec(ixI^S,1:ndim)
      call store_flux(igrid,fluxall,1,ndim,nflux)
      deallocate(fluxall)
    end if

    wres(ixO^S,fl%e_)=qd(ixO^S)

  end subroutine sts_set_source_tc_mhd

  subroutine set_source_tc_mhd(ixI^L,ixO^L,w,x,fl,qvec,rho,Te,alpha)
    use mod_global_parameters

    integer, intent(in) :: ixI^L, ixO^L
    double precision, intent(in) ::  x(ixI^S,1:ndim)
    double precision, intent(in) ::  w(ixI^S,1:nw)
    type(tc_fluid), intent(in) :: fl
    double precision, intent(in) :: rho(ixI^S),Te(ixI^S)
    double precision, intent(in) :: alpha
    double precision, intent(out) :: qvec(ixI^S,1:ndim)

    !! qd store the heat conduction energy changing rate
    double precision :: qd(ixI^S)

    double precision, dimension(ixI^S,1:ndim) :: mf,Bc,Bcf
    double precision, dimension(ixI^S,1:ndim) :: gradT
    double precision, dimension(ixI^S) :: ka,kaf,ke,kef,qdd,qe,Binv,minq,maxq,Bnorm
    double precision, allocatable, dimension(:^D&,:,:) :: fluxall
    integer, dimension(ndim) :: lowindex
    integer :: idims,idir,ix^D,ix^L,ixC^L,ixA^L,ixB^L,ixA^D,ixB^D

    ix^L=ixO^L^LADD1;

    ! T gradient at cell faces
    ! B vector
    if(B0field) then
      mf(ixI^S,1:ndim)=w(ixI^S,iw_mag(1:ndim))+block%B0(ixI^S,1:ndim,0)
    else
      mf(ixI^S,1:ndim)=w(ixI^S,iw_mag(1:ndim))
    end if
    ! |B|
    Binv=dsqrt(sum(mf**2,dim=ndim+1))
    {do ix^DB=ixmin^DB,ixmax^DB\}
      if(Binv(ix^D)/=0.d0) then
        Binv(ix^D)=1.d0/Binv(ix^D)
      else
        Binv(ix^D)=bigdouble
      end if
    {end do\}
    ! b unit vector: magnetic field direction vector
    do idims=1,ndim
      mf(ix^S,idims)=mf(ix^S,idims)*Binv(ix^S)
    end do
    ! ixC is cell-corner index
    ixCmax^D=ixOmax^D; ixCmin^D=ixOmin^D-1;
    ! b unit vector at cell corner
    Bc=0.d0
    {do ix^DB=0,1\}
      ixAmin^D=ixCmin^D+ix^D;
      ixAmax^D=ixCmax^D+ix^D;
      Bc(ixC^S,1:ndim)=Bc(ixC^S,1:ndim)+mf(ixA^S,1:ndim)
    {end do\}
    Bc(ixC^S,1:ndim)=Bc(ixC^S,1:ndim)*0.5d0**ndim
    ! T gradient at cell faces
    do idims=1,ndim
      ixBmin^D=ixmin^D;
      ixBmax^D=ixmax^D-kr(idims,^D);
      call gradientC(Te,ixI^L,ixB^L,idims,minq)
      gradT(ixB^S,idims)=minq(ixB^S)
    end do
    if(fl%tc_constant) then
      if(fl%tc_perpendicular) then
        ka(ixC^S)=fl%tc_k_para-fl%tc_k_perp
        ke(ixC^S)=fl%tc_k_perp
      else
        ka(ixC^S)=fl%tc_k_para
      end if
    else
      ! conductivity at cell center
      if(phys_trac) then
        minq(ix^S)=Te(ix^S)
       {do ix^DB=ixmin^DB,ixmax^DB\}
          if(minq(ix^D) < block%wextra(ix^D,fl%Tcoff_)) then
            minq(ix^D)=block%wextra(ix^D,fl%Tcoff_)
          end if
       {end do\}
        minq(ix^S)=fl%tc_k_para*sqrt(minq(ix^S)**5)
      else
        minq(ix^S)=fl%tc_k_para*sqrt(Te(ix^S)**5)
      end if
      ka=0.d0
      {do ix^DB=0,1\}
        ixBmin^D=ixCmin^D+ix^D;
        ixBmax^D=ixCmax^D+ix^D;
        ka(ixC^S)=ka(ixC^S)+minq(ixB^S)
      {end do\}
      ! cell corner conductivity
      ka(ixC^S)=0.5d0**ndim*ka(ixC^S)
      ! compensate with perpendicular conductivity
      if(fl%tc_perpendicular) then
        minq(ix^S)=fl%tc_k_perp*rho(ix^S)**2*Binv(ix^S)**2/dsqrt(Te(ix^S))
        ke=0.d0
        {do ix^DB=0,1\}
          ixBmin^D=ixCmin^D+ix^D;
          ixBmax^D=ixCmax^D+ix^D;
          ke(ixC^S)=ke(ixC^S)+minq(ixB^S)
        {end do\}
        ! cell corner conductivity: k_parallel-k_perpendicular
        ke(ixC^S)=0.5d0**ndim*ke(ixC^S)
       {do ix^DB=ixCmin^DB,ixCmax^DB\}
          if(ke(ix^D)<ka(ix^D)) then
            ka(ix^D)=ka(ix^D)-ke(ix^D)
          else
            ke(ix^D)=ka(ix^D)
            ka(ix^D)=0.d0
          end if
       {end do\}
      end if
    end if
    if(fl%tc_slope_limiter==0) then
      ! calculate thermal conduction flux with symmetric scheme
      do idims=1,ndim
        !qd corner values
        qd=0.d0
        {do ix^DB=0,1 \}
           if({ ix^D==0 .and. ^D==idims | .or.}) then
             ixBmin^D=ixCmin^D+ix^D;
             ixBmax^D=ixCmax^D+ix^D;
             qd(ixC^S)=qd(ixC^S)+gradT(ixB^S,idims)
           end if
        {end do\}
        ! temperature gradient at cell corner
        qvec(ixC^S,idims)=qd(ixC^S)*0.5d0**(ndim-1)
      end do
      ! b grad T at cell corner
      qd(ixC^S)=0.d0
      do idims=1,ndim
       qd(ixC^S)=qvec(ixC^S,idims)*Bc(ixC^S,idims)+qd(ixC^S)
      end do
      do idims=1,ndim
        ! TC flux at cell corner
        gradT(ixC^S,idims)=ka(ixC^S)*Bc(ixC^S,idims)*qd(ixC^S)
        if(fl%tc_perpendicular) gradT(ixC^S,idims)=gradT(ixC^S,idims)+ke(ixC^S)*qvec(ixC^S,idims)
      end do
      ! TC flux at cell face
      qvec=0.d0
      do idims=1,ndim
        ixB^L=ixO^L-kr(idims,^D);
        ixAmax^D=ixOmax^D; ixAmin^D=ixBmin^D;
        {do ix^DB=0,1 \}
           if({ ix^D==0 .and. ^D==idims | .or.}) then
             ixBmin^D=ixAmin^D-ix^D;
             ixBmax^D=ixAmax^D-ix^D;
             qvec(ixA^S,idims)=qvec(ixA^S,idims)+gradT(ixB^S,idims)
           end if
        {end do\}
        qvec(ixA^S,idims)=qvec(ixA^S,idims)*0.5d0**(ndim-1)
        if(fl%tc_saturate) then
          ! consider saturation (Cowie and Mckee 1977 ApJ, 211, 135)
          ! unsigned saturated TC flux = 5 phi rho c**3, c is isothermal sound speed
          Bcf=0.d0
          {do ix^DB=0,1 \}
             if({ ix^D==0 .and. ^D==idims | .or.}) then
               ixBmin^D=ixAmin^D-ix^D;
               ixBmax^D=ixAmax^D-ix^D;
               Bcf(ixA^S,idims)=Bcf(ixA^S,idims)+Bc(ixB^S,idims)
             end if
          {end do\}
          ! averaged b at face centers
          Bcf(ixA^S,idims)=Bcf(ixA^S,idims)*0.5d0**(ndim-1)
          ixB^L=ixA^L+kr(idims,^D);
          qd(ixA^S)=2.75d0*(rho(ixA^S)+rho(ixB^S))*dsqrt(0.5d0*(Te(ixA^S)+Te(ixB^S)))**3*dabs(Bcf(ixA^S,idims))
         {do ix^DB=ixAmin^DB,ixAmax^DB\}
            if(dabs(qvec(ix^D,idims))>qd(ix^D)) then
              qvec(ix^D,idims)=sign(1.d0,qvec(ix^D,idims))*qd(ix^D)
            end if
         {end do\}
        end if
      end do
    else
      ! calculate thermal conduction flux with slope-limited symmetric scheme
      qvec=0.d0
      do idims=1,ndim
        ixB^L=ixO^L-kr(idims,^D);
        ixAmax^D=ixOmax^D; ixAmin^D=ixBmin^D;
        ! calculate normal of magnetic field
        ixB^L=ixA^L+kr(idims,^D);
        Bnorm(ixA^S)=0.5d0*(mf(ixA^S,idims)+mf(ixB^S,idims))
        Bcf=0.d0
        kaf=0.d0
        kef=0.d0
        {do ix^DB=0,1 \}
           if({ ix^D==0 .and. ^D==idims | .or.}) then
             ixBmin^D=ixAmin^D-ix^D;
             ixBmax^D=ixAmax^D-ix^D;
             Bcf(ixA^S,1:ndim)=Bcf(ixA^S,1:ndim)+Bc(ixB^S,1:ndim)
             kaf(ixA^S)=kaf(ixA^S)+ka(ixB^S)
             if(fl%tc_perpendicular) kef(ixA^S)=kef(ixA^S)+ke(ixB^S)
           end if
        {end do\}
        ! averaged b at face centers
        Bcf(ixA^S,1:ndim)=Bcf(ixA^S,1:ndim)*0.5d0**(ndim-1)
        ! averaged thermal conductivity at face centers
        kaf(ixA^S)=kaf(ixA^S)*0.5d0**(ndim-1)
        if(fl%tc_perpendicular) kef(ixA^S)=kef(ixA^S)*0.5d0**(ndim-1)
        ! limited normal component
        minq(ixA^S)=min(alpha*gradT(ixA^S,idims),gradT(ixA^S,idims)/alpha)
        maxq(ixA^S)=max(alpha*gradT(ixA^S,idims),gradT(ixA^S,idims)/alpha)
        ! eq (19)
        !corner values of gradT
        qdd=0.d0
        {do ix^DB=0,1 \}
           if({ ix^D==0 .and. ^D==idims | .or.}) then
             ixBmin^D=ixCmin^D+ix^D;
             ixBmax^D=ixCmax^D+ix^D;
             qdd(ixC^S)=qdd(ixC^S)+gradT(ixB^S,idims)
           end if
        {end do\}
        ! temperature gradient at cell corner
        qdd(ixC^S)=qdd(ixC^S)*0.5d0**(ndim-1)
        ! eq (21)
        qe=0.d0
        {do ix^DB=0,1 \}
           qd(ixC^S)=qdd(ixC^S)
           if({ ix^D==0 .and. ^D==idims | .or.}) then
             ixBmin^D=ixAmin^D-ix^D;
             ixBmax^D=ixAmax^D-ix^D;
            {do ixA^DB=ixAmin^DB,ixAmax^DB
               ixB^DB=ixA^DB-ix^DB\}
               if(qd(ixB^D)<=minq(ixA^D)) then
                 qd(ixB^D)=minq(ixA^D)
               else if(qd(ixB^D)>=maxq(ixA^D)) then
                 qd(ixB^D)=maxq(ixA^D)
               end if 
            {end do\}
             qvec(ixA^S,idims)=qvec(ixA^S,idims)+Bc(ixB^S,idims)**2*qd(ixB^S)
             if(fl%tc_perpendicular) qe(ixA^S)=qe(ixA^S)+qd(ixB^S)
           end if
        {end do\}
        qvec(ixA^S,idims)=kaf(ixA^S)*qvec(ixA^S,idims)*0.5d0**(ndim-1)
        ! add normal flux from perpendicular conduction
        if(fl%tc_perpendicular) qvec(ixA^S,idims)=qvec(ixA^S,idims)+kef(ixA^S)*qe(ixA^S)*0.5d0**(ndim-1)
        ! limited transverse component, eq (17)
        ixBmin^D=ixAmin^D;
        ixBmax^D=ixAmax^D+kr(idims,^D);
        do idir=1,ndim
          if(idir==idims) cycle
          qd(ixI^S)=slope_limiter(gradT(ixI^S,idir),ixI^L,ixB^L,idir,-1,fl%tc_slope_limiter)
          qd(ixI^S)=slope_limiter(qd,ixI^L,ixA^L,idims,1,fl%tc_slope_limiter)
          qvec(ixA^S,idims)=qvec(ixA^S,idims)+kaf(ixA^S)*Bnorm(ixA^S)*Bcf(ixA^S,idir)*qd(ixA^S)
        end do

        if(fl%tc_saturate) then
          ! consider saturation (Cowie and Mckee 1977 ApJ, 211, 135)
          ! unsigned saturated TC flux = 5 phi rho c**3, c=sqrt(p/rho) is isothermal sound speed, phi=1.1
          ixB^L=ixA^L+kr(idims,^D);
          qd(ixA^S)=2.75d0*(rho(ixA^S)+rho(ixB^S))*dsqrt(0.5d0*(Te(ixA^S)+Te(ixB^S)))**3*dabs(Bnorm(ixA^S))
         {do ix^DB=ixAmin^DB,ixAmax^DB\}
            if(dabs(qvec(ix^D,idims))>qd(ix^D)) then
              !write(*,*) 'it',it,qvec(ix^D,idims),qd(ix^D),' TC saturated at ',&
              !x(ix^D,:),' rho',rho(ix^D),' Te',Te(ix^D)
              qvec(ix^D,idims)=sign(1.d0,qvec(ix^D,idims))*qd(ix^D)
            end if
         {end do\}
        end if
      end do
    end if

  end subroutine set_source_tc_mhd

  function slope_limiter(f,ixI^L,ixO^L,idims,pm,tc_slope_limiter) result(lf)
    use mod_global_parameters
    integer, intent(in) :: ixI^L, ixO^L, idims, pm
    double precision, intent(in) :: f(ixI^S)
    double precision :: lf(ixI^S)
    integer, intent(in)  :: tc_slope_limiter

    double precision :: signf(ixI^S)
    integer :: ixB^L

    ixB^L=ixO^L+pm*kr(idims,^D);
    signf(ixO^S)=sign(1.d0,f(ixO^S))
    select case(tc_slope_limiter)
     case(1)
       ! 'MC' montonized central limiter Woodward and Collela limiter (eq.3.51h), a factor of 2 is pulled out
       lf(ixO^S)=two*signf(ixO^S)* &
            max(zero,min(dabs(f(ixO^S)),signf(ixO^S)*f(ixB^S),&
            signf(ixO^S)*quarter*(f(ixB^S)+f(ixO^S))))
     case(2)
       ! 'minmod' limiter
       lf(ixO^S)=signf(ixO^S)*max(0.d0,min(abs(f(ixO^S)),signf(ixO^S)*f(ixB^S)))
     case(3)
       ! 'superbee' Roes superbee limiter (eq.3.51i)
       lf(ixO^S)=signf(ixO^S)* &
            max(zero,min(two*dabs(f(ixO^S)),signf(ixO^S)*f(ixB^S)),&
            min(dabs(f(ixO^S)),two*signf(ixO^S)*f(ixB^S)))
     case(4)
       ! 'koren' Barry Koren Right variant
       lf(ixO^S)=signf(ixO^S)* &
            max(zero,min(two*dabs(f(ixO^S)),two*signf(ixO^S)*f(ixB^S),&
            (two*f(ixB^S)*signf(ixO^S)+dabs(f(ixO^S)))*third))
     case default
       call mpistop("Unknown slope limiter for thermal conduction")
    end select

  end function slope_limiter

  !> Calculate gradient of a scalar q at cell interfaces in direction idir
  subroutine gradientC(q,ixI^L,ixO^L,idir,gradq)
    use mod_global_parameters

    integer, intent(in)             :: ixI^L, ixO^L, idir
    double precision, intent(in)    :: q(ixI^S)
    double precision, intent(inout) :: gradq(ixI^S)
    integer                         :: jxO^L

    associate(x=>block%x)

    jxO^L=ixO^L+kr(idir,^D);
    select case(coordinate)
    case(Cartesian)
      gradq(ixO^S)=(q(jxO^S)-q(ixO^S))/dxlevel(idir)
    case(Cartesian_stretched)
      gradq(ixO^S)=(q(jxO^S)-q(ixO^S))/(x(jxO^S,idir)-x(ixO^S,idir))
    case(spherical)
      select case(idir)
      case(1)
        gradq(ixO^S)=(q(jxO^S)-q(ixO^S))/(x(jxO^S,1)-x(ixO^S,1))
        {^NOONED
      case(2)
        gradq(ixO^S)=(q(jxO^S)-q(ixO^S))/( (x(jxO^S,2)-x(ixO^S,2))*x(ixO^S,1) )
        }
        {^IFTHREED
      case(3)
        gradq(ixO^S)=(q(jxO^S)-q(ixO^S))/( (x(jxO^S,3)-x(ixO^S,3))*x(ixO^S,1)*dsin(x(ixO^S,2)) )
        }
      end select
    case(cylindrical)
      if(idir==phi_) then
        gradq(ixO^S)=(q(jxO^S)-q(ixO^S))/((x(jxO^S,phi_)-x(ixO^S,phi_))*x(ixO^S,r_))
      else
        gradq(ixO^S)=(q(jxO^S)-q(ixO^S))/(x(jxO^S,idir)-x(ixO^S,idir))
      end if
    case default
      call mpistop('Unknown geometry')
    end select

    end associate
  end subroutine gradientC

  function get_tc_dt_hd(w,ixI^L,ixO^L,dx^D,x,fl)  result(dtnew)
    ! Check diffusion time limit dt < dx_i**2 / ((gamma-1)*tc_k_para_i/rho)
    use mod_global_parameters

    integer, intent(in) :: ixI^L, ixO^L
    double precision, intent(in) :: dx^D, x(ixI^S,1:ndim)
    double precision, intent(in) :: w(ixI^S,1:nw)
    type(tc_fluid), intent(in) :: fl
    double precision :: dtnew

    double precision :: tmp(ixO^S),tmp2(ixO^S),Te(ixI^S),rho(ixI^S),hfs(ixO^S),gradT(ixI^S)
    double precision :: dtdiff_tcond,maxtmp2
    integer          :: idim

    call fl%get_temperature_from_conserved(w,x,ixI^L,ixI^L,Te)
    call fl%get_rho(w,x,ixI^L,ixO^L,rho)

    if(fl%tc_saturate) then
      ! Kannan 2016 MN 458, 410
      ! 3^1.5*kB^2/(4*sqrt(pi)*e^4)
      ! l_mfpe=3.d0**1.5d0*kB_cgs**2/(4.d0*sqrt(dpi)*e_cgs**4*37.d0)=7093.9239487765044d0
      tmp2(ixO^S)=Te(ixO^S)**2/rho(ixO^S)*7093.9239487765044d0*unit_temperature**2/(unit_numberdensity*unit_length)
      hfs=0.d0
      do idim=1,ndim
        call gradient(Te,ixI^L,ixO^L,idim,gradT)
        hfs(ixO^S)=hfs(ixO^S)+gradT(ixO^S)**2
      end do
      ! kappa=kappa_Spizer/(1+4.2*l_mfpe/(T/|gradT|))
      tmp(ixO^S)=fl%tc_k_para*dsqrt((Te(ixO^S))**5)/(rho(ixO^S)*(1.d0+4.2d0*tmp2(ixO^S)*sqrt(hfs(ixO^S))/Te(ixO^S)))
    else
      tmp(ixO^S)=fl%tc_k_para*dsqrt((Te(ixO^S))**5)/rho(ixO^S)
    end if
    dtnew = bigdouble

    if(slab_uniform) then
      do idim=1,ndim
        ! approximate thermal conduction flux: tc_k_para_i/rho/dx
        tmp2(ixO^S)=tmp(ixO^S)/dxlevel(idim)
        maxtmp2=maxval(tmp2(ixO^S))
        ! dt< dx_idim**2/((gamma-1)*tc_k_para_i/rho)
        dtdiff_tcond=dxlevel(idim)/(tc_gamma_1*maxtmp2+smalldouble)
        ! limit the time step
        dtnew=min(dtnew,dtdiff_tcond)
      end do
    else
      do idim=1,ndim
        ! approximate thermal conduction flux: tc_k_para_i/rho/dx
        tmp2(ixO^S)=tmp(ixO^S)/block%ds(ixO^S,idim)
        maxtmp2=maxval(tmp2(ixO^S)/block%ds(ixO^S,idim))
        ! dt< dx_idim**2/((gamma-1)*tc_k_para_i/rho*B_i**2/B**2)
        dtdiff_tcond=1.d0/(tc_gamma_1*maxtmp2+smalldouble)
        ! limit the time step
        dtnew=min(dtnew,dtdiff_tcond)
      end do
    end if
    dtnew=dtnew/dble(ndim)

  end function get_tc_dt_hd

  subroutine sts_set_source_tc_hd(ixI^L,ixO^L,w,x,wres,fix_conserve_at_step,my_dt,igrid,nflux,fl)
    use mod_global_parameters
    use mod_fix_conserve

    integer, intent(in) :: ixI^L, ixO^L, igrid, nflux
    double precision, intent(in) ::  x(ixI^S,1:ndim)
    double precision, intent(in) ::  w(ixI^S,1:nw)
    double precision, intent(inout) ::  wres(ixI^S,1:nw)
    double precision, intent(in) :: my_dt
    logical, intent(in) :: fix_conserve_at_step
    type(tc_fluid), intent(in)    :: fl

    double precision :: Te(ixI^S),rho(ixI^S)
    double precision :: qvec(ixI^S,1:ndim),qd(ixI^S)
    double precision, allocatable, dimension(:^D&,:) :: qvec_equi
    double precision, allocatable, dimension(:^D&,:,:) :: fluxall

    double precision :: dxinv(ndim)
    integer :: idims,ix^L,ixB^L

    ix^L=ixO^L^LADD1;

    dxinv=1.d0/dxlevel

    !calculate Te in whole domain (+ghosts)
    call fl%get_temperature_from_eint(w, x, ixI^L, ixI^L, Te)
    call fl%get_rho(w, x, ixI^L, ixI^L, rho)
    call set_source_tc_hd(ixI^L,ixO^L,w,x,fl,qvec,rho,Te)
    if(fl%has_equi) then
      allocate(qvec_equi(ixI^S,1:ndim))
      call fl%get_temperature_equi(w, x, ixI^L, ixI^L, Te)  !calculate Te in whole domain (+ghosts)
      call fl%get_rho_equi(w, x, ixI^L, ixI^L, rho)  !calculate rho in whole domain (+ghosts)
      call set_source_tc_hd(ixI^L,ixO^L,w,x,fl,qvec_equi,rho,Te)
      do idims=1,ndim
        qvec(ix^S,idims)=qvec(ix^S,idims) - qvec_equi(ix^S,idims)
      end do
      deallocate(qvec_equi)
    endif


    qd=0.d0
    if(slab_uniform) then
      do idims=1,ndim
        qvec(ix^S,idims)=dxinv(idims)*qvec(ix^S,idims)
        ixB^L=ixO^L-kr(idims,^D);
        qd(ixO^S)=qd(ixO^S)+qvec(ixO^S,idims)-qvec(ixB^S,idims)
      end do
    else
      do idims=1,ndim
        qvec(ix^S,idims)=qvec(ix^S,idims)*block%surfaceC(ix^S,idims)
        ixB^L=ixO^L-kr(idims,^D);
        qd(ixO^S)=qd(ixO^S)+qvec(ixO^S,idims)-qvec(ixB^S,idims)
      end do
      qd(ixO^S)=qd(ixO^S)/block%dvolume(ixO^S)
    end if

    if(fix_conserve_at_step) then
      allocate(fluxall(ixI^S,1,1:ndim))
      fluxall(ixI^S,1,1:ndim)=my_dt*qvec(ixI^S,1:ndim)
      call store_flux(igrid,fluxall,1,ndim,nflux)
      deallocate(fluxall)
    end if
    wres(ixO^S,fl%e_)=qd(ixO^S)

  end subroutine sts_set_source_tc_hd

  subroutine set_source_tc_hd(ixI^L,ixO^L,w,x,fl,qvec,rho,Te)
    use mod_global_parameters

    integer, intent(in) :: ixI^L, ixO^L
    double precision, intent(in) ::  x(ixI^S,1:ndim)
    double precision, intent(in) ::  w(ixI^S,1:nw)
    type(tc_fluid), intent(in)    :: fl
    double precision, intent(in) :: Te(ixI^S),rho(ixI^S)
    double precision, intent(out) :: qvec(ixI^S,1:ndim)


    double precision :: gradT(ixI^S,1:ndim),ke(ixI^S),qd(ixI^S)

    integer :: idims,ix^D,ix^L,ixC^L,ixA^L,ixB^L,ixD^L

    ix^L=ixO^L^LADD1;
    ! ixC is cell-corner index
    ixCmax^D=ixOmax^D; ixCmin^D=ixOmin^D-1;

    !{^IFONED
    !! cell corner temperature in ke
    !ke=0.d0
    !ixAmax^D=ixmax^D; ixAmin^D=ixmin^D-1;
    !{do ix^DB=0,1\}
    !  ixBmin^D=ixAmin^D+ix^D;
    !  ixBmax^D=ixAmax^D+ix^D;
    !  ke(ixA^S)=ke(ixA^S)+Te(ixB^S)
    !{end do\}
    !ke(ixA^S)=0.5d0**ndim*ke(ixA^S)
    !do idims=1,ndim
    !  ixBmin^D=ixmin^D;
    !  ixBmax^D=ixmax^D-kr(idims,^D);
    !  call gradient(ke,ixI^L,ixB^L,idims,qd)
    !  gradT(ixB^S,idims)=qd(ixB^S)
    !end do
    !! transition region adaptive conduction
    !if(phys_trac) then
    !  where(ke(ixI^S) < block%wextra(ixI^S,fl%Tcoff_))
    !    ke(ixI^S)=block%wextra(ixI^S,fl%Tcoff_)
    !  end where
    !end if
    !! cell corner conduction flux
    !do idims=1,ndim
    !  gradT(ixC^S,idims)=gradT(ixC^S,idims)*fl%tc_k_para*sqrt(ke(ixC^S)**5)
    !end do
    !}

    ! calculate thermal conduction flux with symmetric scheme
    ! T gradient (central difference) at cell corners
    do idims=1,ndim
      ixBmin^D=ixmin^D;
      ixBmax^D=ixmax^D-kr(idims,^D);
      call gradientC(Te,ixI^L,ixB^L,idims,ke)
      qd=0.d0
     {do ix^DB=0,1 \}
        if({ix^D==0 .and. ^D==idims |.or. }) then
          ixBmin^D=ixCmin^D+ix^D;
          ixBmax^D=ixCmax^D+ix^D;
          qd(ixC^S)=qd(ixC^S)+ke(ixB^S)
        end if
     {end do\}
      ! temperature gradient at cell corner
      qvec(ixC^S,idims)=qd(ixC^S)*0.5d0**(ndim-1)
    end do
    ! conductivity at cell center
    if(phys_trac) then
      ! transition region adaptive conduction
      {do ix^DB=ixmin^DB,ixmax^DB\}
        if(Te(ix^D) < block%wextra(ix^D,fl%Tcoff_)) then
          qd(ix^D)=fl%tc_k_para*dsqrt(block%wextra(ix^D,fl%Tcoff_))**5
        else
          qd(ix^D)=fl%tc_k_para*dsqrt(Te(ix^D))**5
        end if
      {end do\}
    else
      qd(ix^S)=fl%tc_k_para*dsqrt(Te(ix^S))**5
    end if
    ke=0.d0
    {do ix^DB=0,1\}
      ixBmin^D=ixCmin^D+ix^D;
      ixBmax^D=ixCmax^D+ix^D;
      ke(ixC^S)=ke(ixC^S)+qd(ixB^S)
    {end do\}
    ! cell corner conductivity
    ke(ixC^S)=0.5d0**ndim*ke(ixC^S)
    ! cell corner conduction flux
    do idims=1,ndim
      gradT(ixC^S,idims)=ke(ixC^S)*qvec(ixC^S,idims)
    end do

    if(fl%tc_saturate) then
      ! consider saturation with unsigned saturated TC flux = 5 phi rho c**3
      ! saturation flux at cell center
      qd(ix^S)=5.5d0*rho(ix^S)*dsqrt(Te(ix^S)**3)
      !cell corner values of qd in ke
      ke=0.d0
      {do ix^DB=0,1\}
        ixBmin^D=ixCmin^D+ix^D;
        ixBmax^D=ixCmax^D+ix^D;
        ke(ixC^S)=ke(ixC^S)+qd(ixB^S)
      {end do\}
      ! cell corner saturation flux
      ke(ixC^S)=0.5d0**ndim*ke(ixC^S)
      ! magnitude of cell corner conduction flux
      qd(ixC^S)=norm2(gradT(ixC^S,:),dim=ndim+1)
      {do ix^DB=ixCmin^DB,ixCmax^DB\}
        if(qd(ix^D)>ke(ix^D)) then
          ke(ix^D)=ke(ix^D)/(qd(ix^D)+smalldouble)
          do idims=1,ndim
            gradT(ix^D,idims)=ke(ix^D)*gradT(ix^D,idims)
          end do
        end if
      {end do\}
    end if

    ! conduction flux at cell face
    qvec=0.d0
    do idims=1,ndim
      ixB^L=ixO^L-kr(idims,^D);
      ixAmax^D=ixOmax^D; ixAmin^D=ixBmin^D;
      {do ix^DB=0,1 \}
         if({ ix^D==0 .and. ^D==idims | .or.}) then
           ixBmin^D=ixAmin^D-ix^D;
           ixBmax^D=ixAmax^D-ix^D;
           qvec(ixA^S,idims)=qvec(ixA^S,idims)+gradT(ixB^S,idims)
         end if
      {end do\}
      qvec(ixA^S,idims)=qvec(ixA^S,idims)*0.5d0**(ndim-1)
    end do

  end subroutine set_source_tc_hd

end module mod_thermal_conduction
