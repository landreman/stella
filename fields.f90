module fields

  implicit none

  public :: init_fields, finish_fields
  public :: advance_fields, get_fields
  public :: get_fields_by_spec
  public :: gamtot, gamtot3
  public :: time_field_solve
  public :: fields_updated

  private

  real, dimension (:,:,:), allocatable :: gamtot, apar_denom
  real, dimension (:,:), allocatable :: gamtot3
  real :: gamtot_h, gamtot3_h

  real, dimension (2,2) :: time_field_solve

  logical :: fields_updated = .false.
  logical :: fields_initialized = .false.
  logical :: debug = .false.

contains

  subroutine init_fields

    use mp, only: sum_allreduce
    use stella_layouts, only: kxkyz_lo
    use stella_layouts, onlY: iz_idx, it_idx, ikx_idx, iky_idx, is_idx
    use dist_fn_arrays, only: kperp2
    use gyro_averages, only: aj0v
    use run_parameters, only: fphi, fapar
    use physics_parameters, only: tite, nine, beta
    use species, only: spec, has_electron_species
    use stella_geometry, only: dl_over_b
    use zgrid, only: nzgrid
    use vpamu_grids, only: nvpa, nmu
    use vpamu_grids, only: vpa
    use vpamu_grids, only: maxwell_vpa, maxwell_mu
    use vpamu_grids, only: integrate_vmu
    use species, only: spec
    use kt_grids, only: naky, nakx, akx
    use kt_grids, only: zonal_mode
    use dist_fn, only: adiabatic_option_switch
    use dist_fn, only: adiabatic_option_fieldlineavg

    implicit none

    integer :: ikxkyz, iz, it, ikx, iky, is, ia
    real :: tmp, wgt
    real, dimension (:,:), allocatable :: g0

    ia = 1

    ! do not see why this is before fields_initialized check below
    call allocate_arrays

    if (fields_initialized) return
    fields_initialized = .true.

    ! could move these array allocations to allocate_arrays to clean up code
    if (.not.allocated(gamtot)) allocate (gamtot(naky,nakx,-nzgrid:nzgrid)) ; gamtot = 0.
    if (.not.allocated(gamtot3)) then
       if (.not.has_electron_species(spec) &
            .and. adiabatic_option_switch==adiabatic_option_fieldlineavg) then
          allocate (gamtot3(nakx,-nzgrid:nzgrid)) ; gamtot3 = 0.
       else
          allocate (gamtot3(1,1)) ; gamtot3 = 0.
       end if
    end if
    if (.not.allocated(apar_denom)) then
       if (fapar > epsilon(0.0)) then
          allocate (apar_denom(naky,nakx,-nzgrid:nzgrid)) ; apar_denom = 0.
       else
          allocate (apar_denom(1,1,1)) ; apar_denom = 0.
       end if
    end if

    if (fphi > epsilon(0.0)) then
       allocate (g0(nvpa,nmu))
       do ikxkyz = kxkyz_lo%llim_proc, kxkyz_lo%ulim_proc
          it = it_idx(kxkyz_lo,ikxkyz)
          ! gamtot does not depend on flux tube index,
          ! so only compute for one flux tube index
          if (it /= 1) cycle
          iky = iky_idx(kxkyz_lo,ikxkyz)
          ikx = ikx_idx(kxkyz_lo,ikxkyz)
          iz = iz_idx(kxkyz_lo,ikxkyz)
          is = is_idx(kxkyz_lo,ikxkyz)
          g0 = spread((1.0 - aj0v(:,ikxkyz)**2),1,nvpa) &
               * spread(maxwell_vpa,2,nmu)*spread(maxwell_mu(ia,iz,:),1,nvpa)
          wgt = spec(is)%z*spec(is)%z*spec(is)%dens/spec(is)%temp
          call integrate_vmu (g0, iz, tmp)
          gamtot(iky,ikx,iz) = gamtot(iky,ikx,iz) + tmp*wgt
       end do
       call sum_allreduce (gamtot)
       ! avoid divide by zero when kx=ky=0
       ! do not evolve this mode, so value is irrelevant
       if (zonal_mode(1).and.akx(1)<epsilon(0.).and.has_electron_species(spec)) gamtot(1,1,:) = 1.0

       gamtot_h = sum(spec%z*spec%z*spec%dens/spec%temp)

       if (.not.has_electron_species(spec)) then
          gamtot = gamtot + tite/nine
          gamtot_h = gamtot_h + tite/nine
          if (adiabatic_option_switch == adiabatic_option_fieldlineavg) then
             if (zonal_mode(1)) then
                gamtot3_h = tite/(nine*sum(spec%zt*spec%z*spec%dens))
                do ikx = 1, nakx
                   ! avoid divide by zero for kx=ky=0 mode,
                   ! which we do not need anyway
                   if (abs(akx(ikx)) < epsilon(0.)) cycle
                   tmp = nine/tite-sum(dl_over_b(ia,:)/gamtot(1,ikx,:))
                   gamtot3(ikx,:) = 1./(gamtot(1,ikx,:)*tmp)
                end do
             end if
          end if
       end if

       deallocate (g0)

    end if

    if (fapar > epsilon(0.)) then
       allocate (g0(nvpa,nmu))
       do ikxkyz = kxkyz_lo%llim_proc, kxkyz_lo%ulim_proc
          it = it_idx(kxkyz_lo,ikxkyz)
          ! apar_denom does not depend on flux tube index,
          ! so only compute for one flux tube index
          if (it /= 1) cycle
          iky = iky_idx(kxkyz_lo,ikxkyz)
          ikx = ikx_idx(kxkyz_lo,ikxkyz)
          iz = iz_idx(kxkyz_lo,ikxkyz)
          is = is_idx(kxkyz_lo,ikxkyz)
          g0 = spread(maxwell_vpa*vpa**2,2,nmu) &
               * spread(maxwell_mu(ia,iz,:)*aj0v(:,ikxkyz)**2,1,nvpa)
          wgt = 2.0*beta*spec(is)%z*spec(is)%z*spec(is)%dens/spec(is)%mass
          call integrate_vmu (g0, iz, tmp)
          apar_denom(iky,ikx,iz) = apar_denom(iky,ikx,iz) + tmp*wgt
       end do
       call sum_allreduce (apar_denom)
       apar_denom = apar_denom + kperp2(:,:,ia,:)

       deallocate (g0)
    end if

!    if (wstar_implicit) call init_get_fields_wstar

  end subroutine init_fields

  subroutine allocate_arrays

    use fields_arrays, only: phi, apar
    use fields_arrays, only: phi_old
    use zgrid, only: nzgrid, ntubes
    use kt_grids, only: naky, nakx

    implicit none

    if (.not.allocated(phi)) then
       allocate (phi(naky,nakx,-nzgrid:nzgrid,ntubes))
       phi = 0.
    end if
    if (.not. allocated(apar)) then
       allocate (apar(naky,nakx,-nzgrid:nzgrid,ntubes))
       apar = 0.
    end if
    if (.not.allocated(phi_old)) then
       allocate (phi_old(naky,nakx,-nzgrid:nzgrid,ntubes))
       phi_old = 0.
    end if

  end subroutine allocate_arrays

  subroutine advance_fields (g, phi, apar, dist)

    use mp, only: proc0
    use stella_layouts, only: vmu_lo
    use job_manage, only: time_message
    use redistribute, only: scatter
    use dist_fn_arrays, only: gvmu
    use zgrid, only: nzgrid
    use dist_redistribute, only: kxkyz2vmu
    use run_parameters, only: fields_kxkyz

    implicit none

    complex, dimension (:,:,-nzgrid:,:,vmu_lo%llim_proc:), intent (in) :: g
    complex, dimension (:,:,-nzgrid:,:), intent (out) :: phi, apar
    character (*), intent (in) :: dist

    if (fields_updated) return

    ! time the communications + field solve
    if (proc0) call time_message(.false.,time_field_solve(:,1),' fields')
    if (fields_kxkyz) then
       ! first gather (vpa,mu) onto processor for v-space operations
       ! v-space operations are field solve, dg/dvpa, and collisions
       if (debug) write (*,*) 'dist_fn::advance_stella::scatter'
       if (proc0) call time_message(.false.,time_field_solve(:,2),' fields_redist')
       call scatter (kxkyz2vmu, g, gvmu)
       if (proc0) call time_message(.false.,time_field_solve(:,2),' fields_redist')
       ! given gvmu with vpa and mu local, calculate the corresponding fields
       if (debug) write (*,*) 'dist_fn::advance_stella::get_fields'
       call get_fields (gvmu, phi, apar, dist)
    else
       call get_fields_vmulo (g, phi, apar, dist)
    end if

    ! set a flag to indicate that the fields have been updated
    ! this helps avoid unnecessary field solves
    fields_updated = .true.
    ! time the communications + field solve
    if (proc0) call time_message(.false.,time_field_solve(:,1),' fields')

  end subroutine advance_fields

  subroutine get_fields (g, phi, apar, dist)

    use mp, only: proc0
    use mp, only: sum_allreduce, mp_abort
    use stella_layouts, only: kxkyz_lo
    use stella_layouts, only: iz_idx, it_idx, ikx_idx, iky_idx, is_idx
    use dist_fn_arrays, only: kperp2
    use gyro_averages, only: gyro_average
    use run_parameters, only: fphi, fapar
    use physics_parameters, only: beta
    use stella_geometry, only: dl_over_b
    use zgrid, only: nzgrid, ntubes
    use vpamu_grids, only: nvpa, nmu
    use vpamu_grids, only: vpa
    use vpamu_grids, only: integrate_vmu
    use kt_grids, only: nakx
    use kt_grids, only: zonal_mode
    use species, only: spec, has_electron_species
    use dist_fn, only: adiabatic_option_switch
    use dist_fn, only: adiabatic_option_fieldlineavg

    implicit none
    
    complex, dimension (:,:,kxkyz_lo%llim_proc:), intent (in) :: g
    complex, dimension (:,:,-nzgrid:,:), intent (out) :: phi, apar
    character (*), intent (in) :: dist

    real :: wgt
    complex, dimension (:,:), allocatable :: g0
    integer :: ikxkyz, iz, it, ikx, iky, is, ia
    complex :: tmp

    ia = 1

    phi = 0.
    if (fphi > epsilon(0.0)) then
       allocate (g0(nvpa,nmu))
       do ikxkyz = kxkyz_lo%llim_proc, kxkyz_lo%ulim_proc
          iz = iz_idx(kxkyz_lo,ikxkyz)
          it = it_idx(kxkyz_lo,ikxkyz)
          ikx = ikx_idx(kxkyz_lo,ikxkyz)
          iky = iky_idx(kxkyz_lo,ikxkyz)
          is = is_idx(kxkyz_lo,ikxkyz)
          call gyro_average (g(:,:,ikxkyz), ikxkyz, g0)
          wgt = spec(is)%z*spec(is)%dens
          call integrate_vmu (g0, iz, tmp)
          phi(iky,ikx,iz,it) = phi(iky,ikx,iz,it) + wgt*tmp
       end do
       call sum_allreduce (phi)

       if (dist == 'h') then
          phi = phi/gamtot_h
       else if (dist == 'gbar') then
          phi = phi/spread(gamtot,4,ntubes)
!       else if (dist == 'gstar') then
!          phi = phi/gamtot_wstar
       else
          if (proc0) write (*,*) 'unknown dist option in get_fields. aborting'
          call mp_abort ('unknown dist option in get_fields. aborting')
       end if

       if (.not.has_electron_species(spec) .and. &
            adiabatic_option_switch == adiabatic_option_fieldlineavg) then
          if (zonal_mode(1)) then
             if (dist == 'h') then
                do ikx = 1, nakx
                   do it = 1, ntubes
                      tmp = sum(dl_over_b(ia,:)*phi(1,ikx,:,it))
                      phi(1,ikx,:,it) = phi(1,ikx,:,it) + tmp*gamtot3_h
                   end do
                end do
             else if (dist == 'gbar') then
                do ikx = 1, nakx
                   do it = 1, ntubes
                      tmp = sum(dl_over_b(ia,:)*phi(1,ikx,:,it))
                      phi(1,ikx,:,it) = phi(1,ikx,:,it) + tmp*gamtot3(ikx,:)
                   end do
                end do
!             else if (dist == 'gstar') then
!                do ikx = 1, nakx
!                   tmp = sum(dl_over_b*phi(1,ikx,:))
!                   phi(1,ikx,:) = phi(1,ikx,:) + tmp*gamtot3_wstar(ikx,:)
!                end do
             else
                if (proc0) write (*,*) 'unknown dist option in get_fields. aborting'
                call mp_abort ('unknown dist option in get_fields. aborting')
             end if
          end if
       end if

       deallocate (g0)
    end if

    apar = 0.
    if (fapar > epsilon(0.0)) then
       allocate (g0(nvpa,nmu))
       do ikxkyz = kxkyz_lo%llim_proc, kxkyz_lo%ulim_proc
          iz = iz_idx(kxkyz_lo,ikxkyz)
          it = it_idx(kxkyz_lo,ikxkyz)
          ikx = ikx_idx(kxkyz_lo,ikxkyz)
          iky = iky_idx(kxkyz_lo,ikxkyz)
          is = is_idx(kxkyz_lo,ikxkyz)
          call gyro_average (spread(vpa,2,nmu)*g(:,:,ikxkyz), ikxkyz, g0)
          wgt = 2.0*beta*spec(is)%z*spec(is)%dens*spec(is)%stm
          call integrate_vmu (g0, iz, tmp)
          apar(iky,ikx,iz,it) = apar(iky,ikx,iz,it) + tmp*wgt
       end do
       call sum_allreduce (apar)
       if (dist == 'h') then
          apar = apar/spread(kperp2(:,:,ia,:),4,ntubes)
       else if (dist == 'gbar') then
          apar = apar/spread(apar_denom,4,ntubes)
       else if (dist == 'gstar') then
          write (*,*) 'APAR NOT SETUP FOR GSTAR YET. aborting.'
          call mp_abort('APAR NOT SETUP FOR GSTAR YET. aborting.')
       else
          if (proc0) write (*,*) 'unknown dist option in get_fields. aborting'
          call mp_abort ('unknown dist option in get_fields. aborting')
       end if
       deallocate (g0)
    end if
    
  end subroutine get_fields

  subroutine get_fields_vmulo (g, phi, apar, dist)

    use mp, only: proc0, mp_abort
    use stella_layouts, only: vmu_lo
    use gyro_averages, only: gyro_average
    use run_parameters, only: fphi, fapar
    use stella_geometry, only: dl_over_b
    use zgrid, only: nzgrid, ntubes
    use vpamu_grids, only: integrate_species
    use kt_grids, only: nakx, naky
    use kt_grids, only: zonal_mode
    use species, only: spec, has_electron_species
    use dist_fn, only: adiabatic_option_switch
    use dist_fn, only: adiabatic_option_fieldlineavg

    implicit none
    
    complex, dimension (:,:,-nzgrid:,:,vmu_lo%llim_proc:), intent (in) :: g
    complex, dimension (:,:,-nzgrid:,:), intent (out) :: phi, apar
    character (*), intent (in) :: dist

    integer :: ikx, iky, ivmu, iz, it, ia
    complex :: tmp
    complex, dimension (:,:,:), allocatable :: gyro_g

    ia = 1

    phi = 0.
    if (fphi > epsilon(0.0)) then

       allocate (gyro_g(naky,nakx,vmu_lo%llim_proc:vmu_lo%ulim_proc))
       do it = 1, ntubes
          do iz = -nzgrid, nzgrid
             do ivmu = vmu_lo%llim_proc, vmu_lo%ulim_proc
                call gyro_average (g(:,:,iz,it,ivmu), iz, ivmu, gyro_g(:,:,ivmu))
             end do
             call integrate_species (gyro_g, iz, spec%z*spec%dens, phi(:,:,iz,it))
          end do
       end do
       deallocate (gyro_g)

       if (dist == 'h') then
          phi = phi/gamtot_h
       else if (dist == 'gbar') then
          call get_phi (phi)
!          phi = phi/spread(gamtot,4,ntubes)
!       else if (dist == 'gstar') then
!          phi = phi/gamtot_wstar
       else
          if (proc0) write (*,*) 'unknown dist option in get_fields. aborting'
          call mp_abort ('unknown dist option in get_fields. aborting')
       end if

       if (.not.has_electron_species(spec) .and. &
            adiabatic_option_switch == adiabatic_option_fieldlineavg) then
          if (zonal_mode(1)) then
             if (dist == 'h') then
                do it = 1, ntubes
                   do ikx = 1, nakx
                      tmp = sum(dl_over_b(ia,:)*phi(1,ikx,:,it))
                      phi(1,ikx,:,it) = phi(1,ikx,:,it) + tmp*gamtot3_h
                   end do
                end do
             else if (dist == 'gbar') then
                do it = 1, ntubes
                   do ikx = 1, nakx
                      tmp = sum(dl_over_b(ia,:)*phi(1,ikx,:,it))
                      phi(1,ikx,:,it) = phi(1,ikx,:,it) + tmp*gamtot3(ikx,:)
                   end do
                end do
!             else if (dist == 'gstar') then
!                do ikx = 1, nakx
!                   tmp = sum(dl_over_b*phi(1,ikx,:))
!                   phi(1,ikx,:) = phi(1,ikx,:) + tmp*gamtot3_wstar(ikx,:)
!                end do
             else
                if (proc0) write (*,*) 'unknown dist option in get_fields. aborting'
                call mp_abort ('unknown dist option in get_fields. aborting')
             end if
          end if
       end if
    end if
    
    apar = 0.
    if (fapar > epsilon(0.0)) then
       ! FLAG -- NEW LAYOUT NOT YET SUPPORTED !!
       call mp_abort ('APAR NOT YET SUPPORTED FOR NEW FIELD SOLVE. ABORTING.')
!        allocate (g0(-nvgrid:nvgrid,nmu))
!        do ikxkyz = kxkyz_lo%llim_proc, kxkyz_lo%ulim_proc
!           iz = iz_idx(kxkyz_lo,ikxkyz)
!           ikx = ikx_idx(kxkyz_lo,ikxkyz)
!           iky = iky_idx(kxkyz_lo,ikxkyz)
!           is = is_idx(kxkyz_lo,ikxkyz)
!           g0 = spread(aj0v(:,ikxkyz),1,nvpa)*spread(vpa,2,nmu)*g(:,:,ikxkyz)
!           wgt = 2.0*beta*spec(is)%z*spec(is)%dens*spec(is)%stm
!           call integrate_vmu (g0, iz, tmp)
!           apar(iky,ikx,iz) = apar(iky,ikx,iz) + tmp*wgt
!        end do
!        call sum_allreduce (apar)
!        if (dist == 'h') then
!           apar = apar/kperp2
!        else if (dist == 'gbar') then
!           apar = apar/apar_denom
!        else if (dist == 'gstar') then
!           write (*,*) 'APAR NOT SETUP FOR GSTAR YET. aborting.'
!           call mp_abort('APAR NOT SETUP FOR GSTAR YET. aborting.')
!        else
!           if (proc0) write (*,*) 'unknown dist option in get_fields. aborting'
!           call mp_abort ('unknown dist option in get_fields. aborting')
!        end if
!        deallocate (g0)
    end if
    
  end subroutine get_fields_vmulo

  subroutine get_phi (phi)

    use physics_flags, only: full_flux_surface
    use zgrid, only: nzgrid, ntubes
!    use kt_grids, only: naky_all, ikx_max
    use kt_grids, only: swap_kxky_ordered

    implicit none

    complex, dimension (:,:,-nzgrid:,:), intent (in out) :: phi

!    integer :: it, iz
!    complex, dimension (:,:), allocatable :: phi_swap

    if (full_flux_surface) then
!        ! need to invert 1-gamma0 operator
!        allocate (phi_swap(naky_all,ikx_max))
!        do it = 1, ntubes
!           do iz = -nzgrid, nzgrid
!              call swap_kxky_ordered (phi, phi_swap)
!              do ikx = 1, ikx_max
!                 ! if ky values uncoupled, then obtain phi by simple divide
!                 if (maxval(ia_max_gam0a(:,ikx,iz)) == 1) then
!                    phi_swap(:,ikx) = phi_swap(:,ikx)/gam0a(1,:,ikx,iz)
!                 else
!                    ! for ky values that require info from other ky values
!                    ! must solve linear system
!                    call 
!                 end if
!              end do
!           end do
!        end do
!        deallocate (phi_swap)
    else
       phi = phi/spread(gamtot,4,ntubes)
    end if

  end subroutine get_phi

  subroutine get_fields_by_spec (g, fld)

    use mp, only: sum_allreduce
    use stella_layouts, only: kxkyz_lo
    use stella_layouts, only: iz_idx, it_idx, ikx_idx, iky_idx, is_idx
    use gyro_averages, only: gyro_average
    use run_parameters, only: fphi
    use stella_geometry, only: dl_over_b
    use zgrid, only: nzgrid, ntubes
    use vpamu_grids, only: nvpa, nmu
    use vpamu_grids, only: integrate_vmu
    use kt_grids, only: nakx
    use kt_grids, only: zonal_mode
    use species, only: spec, nspec, has_electron_species
    use dist_fn, only: adiabatic_option_switch
    use dist_fn, only: adiabatic_option_fieldlineavg

    implicit none
    
    complex, dimension (:,:,kxkyz_lo%llim_proc:), intent (in) :: g
    complex, dimension (:,:,-nzgrid:,:,:), intent (out) :: fld

    real :: wgt
    complex, dimension (:,:), allocatable :: g0
    integer :: ikxkyz, iz, it, ikx, iky, is, ia
    complex, dimension (nspec) :: tmp

    ia = 1

    fld = 0.
    if (fphi > epsilon(0.0)) then
       allocate (g0(nvpa,nmu))
       do ikxkyz = kxkyz_lo%llim_proc, kxkyz_lo%ulim_proc
          iz = iz_idx(kxkyz_lo,ikxkyz)
          it = it_idx(kxkyz_lo,ikxkyz)
          ikx = ikx_idx(kxkyz_lo,ikxkyz)
          iky = iky_idx(kxkyz_lo,ikxkyz)
          is = is_idx(kxkyz_lo,ikxkyz)
          wgt = spec(is)%z*spec(is)%dens
          call gyro_average (g(:,:,ikxkyz), ikxkyz, g0)
          g0 = g0*wgt
          call integrate_vmu (g0, iz, fld(iky,ikx,iz,it,is))
       end do
       call sum_allreduce (fld)

       fld = fld/gamtot_h

       if (.not.has_electron_species(spec) .and. &
            adiabatic_option_switch == adiabatic_option_fieldlineavg) then
          if (zonal_mode(1)) then
             do ikx = 1, nakx
                do it = 1, ntubes
                   do is = 1, nspec
                      tmp(is) = sum(dl_over_b(ia,:)*fld(1,ikx,:,it,is))
                      fld(1,ikx,:,it,is) = fld(1,ikx,:,it,is) + tmp(is)*gamtot3_h
                   end do
                end do
             end do
          end if
       end if

       deallocate (g0)
    end if

  end subroutine get_fields_by_spec

  subroutine finish_fields

    use fields_arrays, only: phi, phi_old
    use fields_arrays, only: apar

    implicit none

    if (allocated(phi)) deallocate (phi)
    if (allocated(phi_old)) deallocate (phi_old)
    if (allocated(apar)) deallocate (apar)
    if (allocated(gamtot)) deallocate (gamtot)
    if (allocated(gamtot3)) deallocate (gamtot3)
    if (allocated(apar_denom)) deallocate (apar_denom)

    fields_initialized = .false.

  end subroutine finish_fields

end module fields
