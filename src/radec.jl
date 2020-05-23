# Compute astrometric right ascension and declination for an asteroid at
# UTC instant `t_r_utc` from tracking station with code `station_code` from Earth,
# Sun and asteroid ephemerides
# station_code: observing station identifier (MPC nomenclature)
# t_r_utc: UTC time of astrometric observation (DateTime)
# niter: number of light-time solution iterations
# xve: Earth ephemeris wich takes et seconds since J2000 as input and returns Earth barycentric position in km and velocity in km/second
# xvs: Sun ephemeris wich takes et seconds since J2000 as input and returns Sun barycentric position in km and velocity in km/second
# xva: asteroid ephemeris wich takes et seconds since J2000 as input and returns asteroid barycentric position in km and velocity in km/second
function radec(station_code::Union{Int,String}, t_r_utc::DateTime,
        niter::Int=10; pm::Bool=true, xve::Function=earth_pv, xvs::Function=sun_pv,
        xva::Function=apophis_pv_197)
    et_r_secs = str2et(string(t_r_utc))
    # Compute geocentric position/velocity of receiving antenna in inertial frame (au, au/day)
    R_r, V_r = observer_position(station_code, et_r_secs, pm=pm)
    # Earth's barycentric position and velocity at receive time
    rv_e_t_r = xve(et_r_secs)
    r_e_t_r = rv_e_t_r[1:3]
    v_e_t_r = rv_e_t_r[4:6]
    # Receiver barycentric position and velocity at receive time
    r_r_t_r = r_e_t_r + R_r
    v_r_t_r = v_e_t_r + V_r
    # Asteroid barycentric position and velocity at receive time
    rv_a_t_r = xva(et_r_secs)
    r_a_t_r = rv_a_t_r[1:3]
    # Sun barycentric position and velocity at receive time
    rv_s_t_r = xvs(et_r_secs)
    r_s_t_r = rv_s_t_r[1:3]
    # down-leg iteration
    # τ_D first approximation: Eq. (1) Yeomans et al. (1992)
    ρ_vec_r = r_a_t_r - r_r_t_r
    ρ_r = sqrt(ρ_vec_r[1]^2 + ρ_vec_r[2]^2 + ρ_vec_r[3]^2)
    τ_D = ρ_r/clightkms # (seconds) -R_b/c, but delay is wrt asteroid Center (Brozovic et al., 2018)
    # bounce time, new estimate Eq. (2) Yeomans et al. (1992)
    et_b_secs = et_r_secs - τ_D

    Δτ_D = zero(τ_D)
    Δτ_rel_D = zero(τ_D)
    # Δτ_corona_D = zero(τ_D)
    Δτ_tropo_D = zero(τ_D)

    for i in 1:niter
        # asteroid barycentric position (in au) at bounce time (TDB)
        rv_a_t_b = xva(et_b_secs)
        r_a_t_b = rv_a_t_b[1:3]
        v_a_t_b = rv_a_t_b[4:6]
        # Eq. (3) Yeomans et al. (1992)
        ρ_vec_r = r_a_t_b - r_r_t_r
        # Eq. (4) Yeomans et al. (1992)
        ρ_r = sqrt(ρ_vec_r[1]^2 + ρ_vec_r[2]^2 + ρ_vec_r[3]^2)
        # compute down-leg Shapiro delay
        # NOTE: when using PPN, substitute 2 -> 1+γ in expressions for Shapiro delay, Δτ_rel_[D|U]
        e_D_vec  = r_r_t_r - r_s_t_r
        e_D = sqrt(e_D_vec[1]^2 + e_D_vec[2]^2 + e_D_vec[3]^2) # heliocentric distance of Earth at t_r
        rv_s_t_b = xvs(et_b_secs) # barycentric position and velocity of Sun at estimated bounce time
        r_s_t_b = rv_s_t_b[1:3]
        p_D_vec  = r_a_t_b - r_s_t_b
        p_D = sqrt(p_D_vec[1]^2 + p_D_vec[2]^2 + p_D_vec[3]^2) # heliocentric distance of asteroid at t_b
        q_D = ρ_r #signal path distance (down-leg)
        # Shapiro correction to time-delay
        Δτ_rel_D = shapiro_delay(e_D, p_D, q_D)
        # troposphere correction to time-delay
        Δτ_tropo_D = tropo_delay(R_r, ρ_vec_r) # seconds
        # Δτ_corona_D = corona_delay(constant_term.(r_a_t_b), r_r_t_r, r_s_t_r, F_tx, station_code) # seconds
        Δτ_D = Δτ_rel_D # + Δτ_tropo_D #+ Δτ_corona_D # seconds
        p_dot_23 = dot(ρ_vec_r, v_a_t_b)/ρ_r
        Δt_2 = (τ_D - ρ_r/clightkms - Δτ_rel_D)/(1.0-p_dot_23/clightkms)
        τ_D = τ_D - Δt_2
        et_b_secs = et_r_secs - τ_D
    end
    rv_a_t_b = xva(et_b_secs)
    r_a_t_b = rv_a_t_b[1:3]
    v_a_t_b = rv_a_t_b[4:6]

    ρ_vec_r = r_a_t_b - r_r_t_r
    ρ_r = sqrt(ρ_vec_r[1]^2 + ρ_vec_r[2]^2 + ρ_vec_r[3]^2)

    # TODO: add aberration and atmospheric refraction corrections

    # Compute gravitational deflection of light, ESAA 2014 Section 7.4.1.4
    E_H_vec = r_r_t_r -r_s_t_r # ESAA 2014, Eq. (7.104)
    U_vec = ρ_vec_r #r_a_t_b - r_e_t_r # ESAA 2014, Eq. (7.112)
    U_norm = ρ_r # sqrt(U_vec[1]^2 + U_vec[2]^2 + U_vec[3]^2)
    u_vec = U_vec/U_norm
    rv_s_t_b = xvs(et_b_secs) # barycentric position and velocity of Sun at converged bounce time
    r_s_t_b = rv_s_t_b[1:3]
    Q_vec = r_a_t_b - r_s_t_b # ESAA 2014, Eq. (7.113)
    q_vec = Q_vec/sqrt(Q_vec[1]^2 + Q_vec[2]^2 + Q_vec[3]^2)
    E_H = sqrt(E_H_vec[1]^2 + E_H_vec[2]^2 + E_H_vec[3]^2)
    e_vec = E_H_vec/E_H
    g1 = (2μ[1]/(c_au_per_day^2))/(E_H/au) # ESAA 2014, Eq. (7.115)
    g2 = 1 + dot(q_vec, e_vec)
    # @show g1, g2
    u1_vec = U_norm*(  u_vec + (g1/g2)*( dot(u_vec,q_vec)*e_vec - dot(e_vec,u_vec)*q_vec )  ) # ESAA 2014, Eq. (7.116)

    # Compute aberration of light, ESAA 2014 Section 7.4.1.5
    u1_norm = sqrt(u1_vec[1]^2 + u1_vec[2]^2 + u1_vec[3]^2)
    # @show norm(u1_vec/U_norm), μ[1]/(c_au_per_day^2) # u1_vec/U_norm is a unit vector to order μ[1]/(c_au_per_day^2)
    u_vec_new = u1_vec/u1_norm
    V_vec = v_r_t_r/clightkms
    V_norm = sqrt(V_vec[1]^2 + V_vec[2]^2 + V_vec[3]^2)
    β_m1 = sqrt(1-V_norm^2) # β^-1
    # @show norm(v_r_t_r), V_norm, β_m1
    # @show β_m1
    f1 = dot(u_vec_new, V_vec)
    f2 = 1 + f1/(1+β_m1)
    # u2_vec = ρ_vec_r; u2_norm = ρ_r # uncorrected radial unit vector
    # u2_vec = u1_vec; u2_norm = sqrt(u2_vec[1]^2 + u2_vec[2]^2 + u2_vec[3]^2) # radial unit vector with grav deflection corr.
    # u2_vec = ( β_m1*u1_vec + f2*u1_norm*V_vec )/( 1+f1 ) # ESAA 2014, Eq. (7.118)
    # u2_norm = sqrt(u2_vec[1]^2 + u2_vec[2]^2 + u2_vec[3]^2)
    u2_vec = u1_vec #/U_norm + V_vec # ESAA 2014, Eq. (7.118)
    u2_norm = sqrt(u2_vec[1]^2 + u2_vec[2]^2 + u2_vec[3]^2)

    # Compute right ascension, declination angles
    dec_rad = asin(u2_vec[3]/u2_norm) # declination (rad)
    ra_rad0 = atan(u2_vec[2]/u2_vec[1])
    ra_rad1 = atan(constant_term(u2_vec[2]), constant_term(u2_vec[1])) + (ra_rad0 - constant_term(ra_rad0)) # workaround for TaylorSeries.atan
    ra_rad = mod(ra_rad1, 2pi) # right ascension (rad)

    dec_deg = dec_rad*(180/pi) # rad -> deg
    ra_rah = ra_rad*(180/pi)/15 # rad -> r.a. hours

    return ra_rah, dec_deg # right ascension, declination (r.a. hours, degrees)
end

function radec(astopticalobsfile::String,
        niter::Int=10; pm::Bool=true, xve::Function=earth_pv,
        xvs::Function=sun_pv, xva::Function=apophis_pv_197)
    # astopticalobsfile = "tholenetal2013_radec_data.dat"
    astopticalobsdata = readdlm(astopticalobsfile, ',', comments=true)

    utc1 = DateTime(astopticalobsdata[1,1]) + Microsecond( round(1e6daysec*astopticalobsdata[1,2]) )
    et1 = str2et(string(utc1))
    a1_et1 = xva(et1)[1]
    S = typeof(a1_et1)

    n_optical_obs = size(astopticalobsdata)[1]

    vra = Array{S}(undef, n_optical_obs)
    vdec = Array{S}(undef, n_optical_obs)

    for i in 1:n_optical_obs
        utc_i = DateTime(astopticalobsdata[i,1]) + Microsecond( round(1e6daysec*astopticalobsdata[i,2]) )
        station_code_i = string(astopticalobsdata[i,17])
        vra[i], vdec[i] = radec(station_code_i, utc_i, niter, pm=pm, xve=xve, xvs=xvs, xva=xva)
    end

    return vra, vdec
end

function radec_mpc_vokr15(niter::Int=10; pm::Bool=true, xve::Function=earth_pv,
        xvs::Function=sun_pv, xva::Function=apophis_pv_197)

    astopticalobsfile = joinpath(dirname(pathof(Apophis)), "../vokrouhlickyetal2015_mpc.dat")
    vokr15 = readdlm(astopticalobsfile, ',', comments=true)

    utc1 = DateTime(vokr15[1,4], vokr15[1,5], vokr15[1,6]) + Microsecond( round(1e6*86400*vokr15[1,7]) )
    et1 = str2et(string(utc1))
    a1_et1 = xva(et1)[1]
    S = typeof(a1_et1)

    n_optical_obs = size(vokr15)[1]

    etv = Array{typeof(et1)}(undef, n_optical_obs)
    vra = Array{S}(undef, n_optical_obs)
    vdec = Array{S}(undef, n_optical_obs)

    for i in 1:n_optical_obs
        utc_i = DateTime(vokr15[i,4], vokr15[i,5], vokr15[i,6]) + Microsecond( round(1e6*86400*vokr15[i,7]) )
        station_code_i = string(vokr15[i,20])
        etv[i] = str2et(string(utc_i))
        vra[i], vdec[i] = radec(station_code_i, utc_i, niter, pm=pm, xve=xve, xvs=xvs, xva=xva)
    end

    return etv, vra, vdec
end