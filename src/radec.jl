@doc raw"""
    radec(station_code::Union{Int,String}, t_r_utc::DateTime, niter::Int=10; eo::Bool=true, 
          xve::Function=earth_pv, xvs::Function=sun_pv, xva::Function=apophis_pv_197)

Compute astrometric right ascension and declination (both in arcsec) for an asteroid at 
UTC instant `t_r_utc` from tracking station with code `station_code` from Earth, Sun and 
asteroid ephemerides.

# Arguments 

- `station_code::Union{Int, String}`: observing station identifier (MPC nomenclature).
- `t_r_utc::DateTime`: UTC time of astrometric observation (DateTime).
- `niter::Int`: number of light-time solution iterations.
- `eo::Bool`: compute corrections due to Earth orientation, LOD, polar motion.
- `xve::Function`: Earth ephemeris wich takes et seconds since J2000 as input and returns Earth barycentric position in km and velocity in km/second.
- `xvs::Function`: Sun ephemeris wich takes et seconds since J2000 as input and returns Sun barycentric position in km and velocity in km/second.
- `xva::Function`: asteroid ephemeris wich takes et seconds since J2000 as input and returns asteroid barycentric position in km and velocity in km/second.
"""
function radec(station_code::Union{Int,String}, t_r_utc::DateTime, niter::Int=10; 
               eo::Bool=true, xve::Function=earth_pv, xvs::Function=sun_pv, xva::Function=apophis_pv_197)
    # Transform receiving time from UTC to TDB seconds since J2000
    et_r_secs = str2et(string(t_r_utc))
    # Compute geocentric position/velocity of receiving antenna in inertial frame (au, au/day)
    R_r, V_r = observer_position(station_code, et_r_secs, eo=eo)
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
    
    # Down-leg iteration
    # τ_D first approximation
    # See equation (1) of https://doi.org/10.1086/116062
    ρ_vec_r = r_a_t_r - r_r_t_r
    ρ_r = sqrt(ρ_vec_r[1]^2 + ρ_vec_r[2]^2 + ρ_vec_r[3]^2)
    # -R_b/c, but delay is wrt asteroid Center (Brozovic et al., 2018)
    τ_D = ρ_r/clightkms # (seconds) 
    # Bounce time, new estimate
    # See equation (2) of https://doi.org/10.1086/116062
    et_b_secs = et_r_secs - τ_D

    # Allocate memmory for time-delays 
    Δτ_D = zero(τ_D)               # Total time delay
    Δτ_rel_D = zero(τ_D)           # Shapiro delay  
    # Δτ_corona_D = zero(τ_D)      # Delay due to Solar corona
    Δτ_tropo_D = zero(τ_D)         # Delay due to Earth's troposphere

    for i in 1:niter
        # Asteroid barycentric position (in au) and velocity (in au/day) at bounce time (TDB)
        rv_a_t_b = xva(et_b_secs)
        r_a_t_b = rv_a_t_b[1:3]
        v_a_t_b = rv_a_t_b[4:6]
        # Estimated position of the asteroid's center of mass relative to the recieve point 
        # See equation (3) of https://doi.org/10.1086/116062
        ρ_vec_r = r_a_t_b - r_r_t_r
        # Magnitude of ρ_vec_r
        # See equation (4) of https://doi.org/10.1086/116062
        ρ_r = sqrt(ρ_vec_r[1]^2 + ρ_vec_r[2]^2 + ρ_vec_r[3]^2)

        # Compute down-leg Shapiro delay
        # NOTE: when using PPN, substitute 2 -> 1+γ in expressions for Shapiro delay, 
        # Δτ_rel_[D|U]

        # Earth's position at t_r
        e_D_vec  = r_r_t_r - r_s_t_r
        # Heliocentric distance of Earth at t_r
        e_D = sqrt(e_D_vec[1]^2 + e_D_vec[2]^2 + e_D_vec[3]^2) 
        # Barycentric position of Sun at estimated bounce time
        rv_s_t_b = xvs(et_b_secs) 
        r_s_t_b = rv_s_t_b[1:3]
        # Heliocentric position of asteroid at t_b
        p_D_vec  = r_a_t_b - r_s_t_b
        # Heliocentric distance of asteroid at t_b
        p_D = sqrt(p_D_vec[1]^2 + p_D_vec[2]^2 + p_D_vec[3]^2) 
        # Signal path distance (down-leg)
        q_D = ρ_r 

        # Shapiro correction to time-delay
        Δτ_rel_D = shapiro_delay(e_D, p_D, q_D)  # seconds
        # Troposphere correction to time-delay
        # Δτ_tropo_D = tropo_delay(R_r, ρ_vec_r) # seconds
        # Solar corona correction to time-delay
        # Δτ_corona_D = corona_delay(constant_term.(r_a_t_b), r_r_t_r, r_s_t_r, F_tx, station_code) # seconds
        # Total time-delay
        Δτ_D = Δτ_rel_D # + Δτ_tropo_D #+ Δτ_corona_D # seconds

        # New estimate 
        p_dot_23 = dot(ρ_vec_r, v_a_t_b)/ρ_r
        # Time delay correction
        Δt_2 = (τ_D - ρ_r/clightkms - Δτ_rel_D)/(1.0-p_dot_23/clightkms)
        # Time delay new estimate 
        τ_D = τ_D - Δt_2
        # Bounce time, new estimate 
        # See equation (2) of https://doi.org/10.1086/116062
        et_b_secs = et_r_secs - τ_D
    end
    # Asteroid barycentric position (in au) and velocity (in au/day) at bounce time (TDB)
    rv_a_t_b = xva(et_b_secs)
    r_a_t_b = rv_a_t_b[1:3]
    v_a_t_b = rv_a_t_b[4:6]
    # Estimated position of the asteroid's center of mass relative to the recieve point 
    # See equation (3) of https://doi.org/10.1086/116062
    ρ_vec_r = r_a_t_b - r_r_t_r
    # Magnitude of ρ_vec_r
    # See equation (4) of https://doi.org/10.1086/116062
    ρ_r = sqrt(ρ_vec_r[1]^2 + ρ_vec_r[2]^2 + ρ_vec_r[3]^2)

    # TODO: add aberration and atmospheric refraction corrections

    # Compute gravitational deflection of light
    # See Explanatory Supplement to the Astronomical Almanac (ESAA) 2014 Section 7.4.1.4
    E_H_vec = r_r_t_r -r_s_t_r    # ESAA 2014, equation (7.104)
    U_vec = ρ_vec_r               # r_a_t_b - r_e_t_r, ESAA 2014, equation (7.112)
    U_norm = ρ_r                  # sqrt(U_vec[1]^2 + U_vec[2]^2 + U_vec[3]^2)
    u_vec = U_vec/U_norm
    # Barycentric position and velocity of Sun at converged bounce time
    rv_s_t_b = xvs(et_b_secs) 
    r_s_t_b = rv_s_t_b[1:3]
    Q_vec = r_a_t_b - r_s_t_b     # ESAA 2014, equation (7.113)
    q_vec = Q_vec/sqrt(Q_vec[1]^2 + Q_vec[2]^2 + Q_vec[3]^2)
    E_H = sqrt(E_H_vec[1]^2 + E_H_vec[2]^2 + E_H_vec[3]^2)
    e_vec = E_H_vec/E_H
    # See ESAA 2014, equation (7.115)
    g1 = (2PlanetaryEphemeris.μ[su]/(c_au_per_day^2))/(E_H/au) 
    g2 = 1 + dot(q_vec, e_vec)
    # See ESAA 2014, equation (7.116)
    u1_vec = U_norm*(  u_vec + (g1/g2)*( dot(u_vec,q_vec)*e_vec - dot(e_vec,u_vec)*q_vec )  ) 
    u1_norm = sqrt(u1_vec[1]^2 + u1_vec[2]^2 + u1_vec[3]^2)

    # Compute right ascension, declination angles
    α_rad_ = mod2pi(atan(u1_vec[2], u1_vec[1]))
    α_rad = mod2pi(α_rad_)          # right ascension (rad)
    δ_rad = asin(u1_vec[3]/u1_norm) # declination (rad)

    δ_as = rad2arcsec(δ_rad) # rad -> arcsec + debiasing
    α_as = rad2arcsec(α_rad) # rad -> arcsec + debiasing

    return α_as, δ_as # right ascension, declination (arcsec, arcsec)
end

@doc raw"""
    radec_mpc(astopticalobsfile, niter::Int=10; eo::Bool=true, xve::Function=earth_pv, 
              xvs::Function=sun_pv, xva::Function=apophis_pv_197)

Compute optical astrometric ra/dec (both in arcsec) ephemeris for a set of observations 
in a MPC-formatted file.

See also [`radec`](@ref).

# Arguments

- `astopticalobsfile`: source MPC-formatted file. 
- `niter::Int`: number of light-time solution iterations.
- `eo::Bool`: compute corrections due to Earth orientation, LOD, polar motion.
- `xve::Function`: Earth ephemeris wich takes et seconds since J2000 as input and returns Earth barycentric position in km and velocity in km/second.
- `xvs::Function`: Sun ephemeris wich takes et seconds since J2000 as input and returns Sun barycentric position in km and velocity in km/second.
- `xva::Function`: asteroid ephemeris wich takes et seconds since J2000 as input and returns asteroid barycentric position in km and velocity in km/second.
"""
function radec_mpc(astopticalobsfile, niter::Int=10; eo::Bool=true, xve::Function=earth_pv, 
                   xvs::Function=sun_pv, xva::Function=apophis_pv_197)
    # Read file 
    obs_t = readmp(astopticalobsfile)
    # Number of observations
    n_optical_obs = nrow(obs_t)
    # UTC time of first astrometric observation
    utc1 = DateTime(obs_t[1].yr, obs_t[1].month, obs_t[1].day) + Microsecond( round(1e6*86400*obs_t[1].utc) )
    # TDB seconds since J2000.0 for first astrometric observation
    et1 = str2et(string(utc1))
    # Asteroid ephemeris at et1
    a1_et1 = xva(et1)[1]
    # Tipe of asteroid ephemeris 
    S = typeof(a1_et1)

    # Right ascension
    vra = Array{S}(undef, n_optical_obs)
    # Declination
    vdec = Array{S}(undef, n_optical_obs)

    # Iterate over the number of observations
    for i in 1:n_optical_obs
        # UTC time of i-th astrometric observation
        utc_i = DateTime(obs_t[i].yr, obs_t[i].month, obs_t[i].day) + Microsecond( round(1e6*86400*obs_t[i].utc) )
        # Station code of i-th observation 
        station_code_i = string(obs_t[i].obscode)
        # i-th right ascension and declination
        vra[i], vdec[i] = radec(station_code_i, utc_i, niter, eo=eo, xve=xve, xvs=xvs, xva=xva)
    end

    return vra, vdec # arcsec, arcsec
end

@doc raw"""
    radec_table(mpcobsfile::String, niter::Int=10; eo::Bool=true, debias_table::String="2018",
                xve::Function=earth_pv, xvs::Function=sun_pv, xva::Function=apophis_pv_197)


Compute optical astrometric ra/dec (both in arcsec) ephemeris for a set of observations 
in a MPC-formatted file.

Returns a table with ra/dec astrometry (observed + computed + corrections + statistical
weights) for a set of observations in a MPC_formatted file. 

See also [`radec`](@ref), [`w8sveres17`](@ref) and [`Healpix.ang2pixRing`](@ref). 

# Arguments

- `mpcobsfile::String`: source MPC-formatted file. 
- `niter::Int`: number of light-time solution iterations.
- `eo::Bool`: compute corrections due to Earth orientation, LOD, polar motion.
- `debias_table::String`: debias table for optical observations. 
- `xve::Function`: Earth ephemeris wich takes et seconds since J2000 as input and returns Earth barycentric position in km and velocity in km/second.
- `xvs::Function`: Sun ephemeris wich takes et seconds since J2000 as input and returns Sun barycentric position in km and velocity in km/second.
- `xva::Function`: asteroid ephemeris wich takes et seconds since J2000 as input and returns asteroid barycentric position in km and velocity in km/second.
"""
function radec_table(mpcobsfile::String, niter::Int=10; eo::Bool=true,
        debias_table::String="2018", xve::Function=earth_pv,
        xvs::Function=sun_pv, xva::Function=apophis_pv_197)

    # Read file 
    obs_t = readmp(mpcobsfile)
    # Number of observations 
    n_optical_obs = nrow(obs_t)

    # UTC time of first astrometric observation
    utc1 = DateTime(obs_t.yr[1], obs_t.month[1], obs_t.day[1]) + Microsecond( round(1e6*86400*obs_t.utc[1]) )
    # TDB seconds since J2000.0 for first astrometric observation
    et1 = str2et(string(utc1))
    # Asteroid ephemeris at et1
    a1_et1 = xva(et1)[1]
    # Tipe of asteroid ephemeris 
    S = typeof(a1_et1)
    
    # Observed right ascension
    α_obs = Array{Float64}(undef, n_optical_obs)
    # Observed declination
    δ_obs = Array{Float64}(undef, n_optical_obs)

    # Computed right ascension
    α_comp = Array{S}(undef, n_optical_obs)
    # Computed declination
    δ_comp = Array{S}(undef, n_optical_obs)
    
    # Total debiasing correction in right ascension (arcsec)
    α_corr = Array{Float64}(undef, n_optical_obs)
    # Total debiasing correction in declination (arcsec)
    δ_corr = Array{Float64}(undef, n_optical_obs)
    
    # Computed values
    datetime_obs = Array{DateTime}(undef, n_optical_obs)
    w8s = Array{Float64}(undef, n_optical_obs)

    # Select debiasing table: 
    # - 2014 corresponds to https://doi.org/10.1016/j.icarus.2014.07.033
    # - 2018 corresponds to https://doi.org/10.1016/j.icarus.2019.113596
    # Debiasing tables are loaded "lazily" via Julia artifacts, according to rules in Artifacts.toml
    if debias_table == "2018"
        debias_path = artifact"debias_2018"
        mpc_catalog_codes_201X = mpc_catalog_codes_2018
        # The healpix tesselation resolution of the bias map from https://doi.org/10.1016/j.icarus.2019.113596
        NSIDE= 64 
        # In 2018 debias table Gaia DR2 catalog is regarded as the truth
        truth = "V" 
    elseif debias_table == "hires2018"
        debias_path = artifact"debias_hires2018"
        mpc_catalog_codes_201X = mpc_catalog_codes_2018
        # The healpix tesselation resolution of the high-resolution bias map from https://doi.org/10.1016/j.icarus.2019.113596
        NSIDE= 256 
        # In 2018 debias table Gaia DR2 catalog is regarded as the truth
        truth = "V" 
    elseif debias_table == "2014"
        debias_path = artifact"debias_2014"
        mpc_catalog_codes_201X = mpc_catalog_codes_2014
        # The healpix tesselation resolution of the bias map from https://doi.org/10.1016/j.icarus.2014.07.033
        NSIDE= 64 
        # In 2014 debias table PPMXL catalog is regarded as the truth
        truth = "t" 
    else
        @error "Unknown bias map: $(debias_table). Possible values are `2014`, `2018` and `hires2018`."
    end
    # Debias table file 
    bias_file = joinpath(debias_path, "bias.dat")
    # Read bias matrix 
    bias_matrix = readdlm(bias_file, comment_char='!', comments=true)
    # Initialize healpix Resolution variable
    resol = Resolution(NSIDE) 
    # Compatibility between bias matrix and resolution 
    @assert size(bias_matrix) == (resol.numOfPixels, 4length(mpc_catalog_codes_201X)) "Bias table file $bias_file dimensions do not match expected parameter NSIDE=$NSIDE and/or number of catalogs in table."

    # Iterate over the observations 
    for i in 1:n_optical_obs
        # Observed values
        # the following if block handles the sign of declination, including edge cases 
        # in declination such as -00 01
        if obs_t.signdec[i] == "+"
            δ_i_deg = +(obs_t.decd[i] + obs_t.decm[i]/60 + obs_t.decs[i]/3600) # deg
        elseif obs_t.signdec[i] == "-"
            δ_i_deg = -(obs_t.decd[i] + obs_t.decm[i]/60 + obs_t.decs[i]/3600) # deg
        else
            @warn "Could not parse declination sign: $(obs_t[i].signdec). Setting positive sign."
            δ_i_deg =  (obs_t.decd[i] + obs_t.decm[i]/60 + obs_t.decs[i]/3600) # deg
        end
        # Observed declination
        δ_i_rad = deg2rad(δ_i_deg)          # rad
        # Observed right ascension
        α_i_deg = 15(obs_t.rah[i] + obs_t.ram[i]/60 + obs_t.ras[i]/3600) # deg
        α_i_rad = deg2rad(α_i_deg)          #rad
        # Observed ra/dec 
        δ_obs[i] = 3600δ_i_deg              # arcsec
        α_obs[i] = 3600α_i_deg*cos(δ_i_rad) # arcsec

        # Computed values
        datetime_obs[i] = DateTime(obs_t.yr[i], obs_t.month[i], obs_t.day[i]) + Microsecond( round(1e6*86400*obs_t.utc[i]) )
        # utc_i = datetime_obs[i]
        # Station code 
        station_code_i = string(obs_t.obscode[i])
        # Computed ra/dec
        α_comp_as, δ_comp_as = radec(station_code_i, datetime_obs[i], niter, eo=eo, xve=xve, xvs=xvs, xva=xva)
        # Multiply by metric factor cos(DEC)
        α_comp[i] = α_comp_as*cos(δ_i_rad)  # arcsec 
        δ_comp[i] = δ_comp_as               # arcsec
        # Statistical weights from Veres et al. (2017)
        w8s[i] = w8sveres17(station_code_i, datetime_obs[i], obs_t.catalog[i])


        if (obs_t.catalog[i] ∉ mpc_catalog_codes_201X) && obs_t.catalog[i] != "Y"
            # Handle case: if star catalog not present in debiasing table, then set corrections equal to zero
            if haskey(mpc_catalog_codes, obs_t.catalog[i])
                if obs_t.catalog[i] != truth
                    catalog_not_found = mpc_catalog_codes[obs_t.catalog[i]]
                    @warn "Catalog not found in $(debias_table) table: $(catalog_not_found). Setting debiasing corrections equal to zero."
                end
            elseif obs_t.catalog[i] == " "
                @warn "Catalog information not available in observation record. Setting debiasing corrections equal to zero."
            else
                @warn "Catalog code $(obs_t.catalog[i]) does not correspond to MPC catalog code. Setting debiasing corrections equal to zero."
            end
            α_corr[i] = 0.0
            δ_corr[i] = 0.0
            continue
        else
            # Otherwise, if star catalog is present in debias table, compute corrections
            # get pixel tile index, assuming iso-latitude rings indexing, which is the formatting in tiles.dat
            # substracting 1 from the returned value of `ang2pixRing` corresponds to 0-based indexing, as in tiles.dat
            # not substracting 1 from the returned value of `ang2pixRing` corresponds to 1-based indexing, as in Julia
            # since we use pix_ind to get the corresponding row number in bias.dat, it's not necessary to substract 1
            # @show α_i_rad δ_i_rad π/2-δ_i_rad
            pix_ind = ang2pixRing(resol, π/2-δ_i_rad, α_i_rad)
            # Healpix.pix2angRing(resol, pix_ind)
            # @show Healpix.pix2angRing(resol, pix_ind)
            # Handle edge case: in new MPC catalog nomenclature, "UCAC-5"->"Y"; but in debias tables "UCAC-5"->"W"
            if obs_t.catalog[i] == "Y"
                cat_ind = findfirst(x->x=="W", mpc_catalog_codes_201X)
            else
                cat_ind = findfirst(x->x==obs_t.catalog[i], mpc_catalog_codes_201X)
            end
            # @show pix_ind, cat_ind
            # read dRA, pmRA, dDEC, pmDEC data from bias.dat
            # dRA, position correction in RA*cos(DEC) at epoch J2000.0 [arcsec];
            # dDEC, position correction in DEC at epoch J2000.0 [arcsec];
            # pmRA, proper motion correction in RA*cos(DEC) [mas/yr];
            # pmDEC, proper motion correction in DEC [mas/yr].
            dRA, dDEC, pmRA, pmDEC = bias_matrix[pix_ind, 4*cat_ind-3:4*cat_ind]
            # @show dRA, dDEC, pmRA, pmDEC
            # utc_i = DateTime(obs_t.yr[i], obs_t.month[i], obs_t.day[i]) + Microsecond( round(1e6*86400*obs_t.utc[i]) )
            et_secs_i = str2et(string(datetime_obs[i]))
            tt_secs_i = et_secs_i - ttmtdb(et_secs_i)
            yrs_J2000_tt = tt_secs_i/(daysec*yr)
            # Total debiasing correction in right ascension (arcsec)
            α_corr[i] = dRA + yrs_J2000_tt*pmRA/1000 
            # Total debiasing correction in declination (arcsec)
            δ_corr[i] = dDEC + yrs_J2000_tt*pmDEC/1000 
        end
    end

    # Add columns

    # Time of observation
    obs_t.dt_utc_obs = datetime_obs       
    # Observed ra/dec 
    obs_t.α_obs = α_obs                   
    obs_t.δ_obs = δ_obs
    # Computed ra/dec 
    obs_t.α_comp = α_comp                 
    obs_t.δ_comp = δ_comp                 
    # Total debiasing correction in ra/dec
    obs_t.α_corr = α_corr
    obs_t.δ_corr = δ_corr
    # Statistical weights
    obs_t.σ = w8s
    select

    return obs_t
end

# MPC minor planet optical observations fixed-width format
# Format is described in: https://minorplanetcenter.net/iau/info/OpticalObs.html
# Format is discussed thoroughly in pages 158-181 of https://doi.org/10.1016/j.icarus.2010.06.003
# Column 72: star catalog that was used in the reduction of the astrometry
# Column 15: measurement technique, or observation type
const mpc_format_mp = (mpnum=(1,5,String),
provdesig=(6,12,String),
discovery=(13,13,String),
publishnote=(14,14,String),
j2000=(15,15,String), # TODO: change name (e.g., obstech) to indicate observation technique
yr=(16,19,Int),
month=(21,22,Int),
day=(24,25,Int),
utc=(26,32,Float64),
rah=(33,34,Int),
ram=(36,37,Int),
ras=(39,44,Float64),
signdec=(45,45,String),
decd=(46,47,Int),
decm=(49,50,Int),
decs=(52,56,Float64),
info1=(57,65,String),
magband=(66,71,String),
catalog=(72,72,String),
info2=(73,77,String),
obscode=(78,80,String)
)

# MPC minor planet optical observations reader
readmp(mpcfile::String) = readfwf(mpcfile, mpc_format_mp)

# `mpc_catalog_codes_2014` corresponds to debiasing tables included in https://doi.org/10.1016/j.icarus.2014.07.033
mpc_catalog_codes_2014 = ["a", "b", "c", "d", "e", "g", "i", "j", "l", "m",
"o", "p", "q", "r",
"u", "v", "w", "L", "N"]

# `mpc_catalog_codes_2018` corresponds to debiasing tables included in https://doi.org/10.1016/j.icarus.2019.113596
mpc_catalog_codes_2018 = ["a", "b", "c", "d", "e", "g", "i", "j", "l", "m",
    "n", "o", "p", "q", "r",
    "t", "u", "v", "w", "L", "N",
    "Q", "R", "S", "U", "W"
]

# MPC star catalog codes are were retrieved from the link below
# https://minorplanetcenter.net/iau/info/CatalogueCodes.html
mpc_catalog_codes = Dict(
    "a" =>   "USNO-A1.0",
    "b" =>   "USNO-SA1.0",
    "c" =>   "USNO-A2.0",
    "d" =>   "USNO-SA2.0",
    "e" =>   "UCAC-1",
    "f" =>   "Tycho-1",
    "g" =>   "Tycho-2",
    "h" =>   "GSC-1.0",
    "i" =>   "GSC-1.1",
    "j" =>   "GSC-1.2",
    "k" =>   "GSC-2.2",
    "l" =>   "ACT",
    "m" =>   "GSC-ACT",
    "n" =>   "SDSS-DR8",
    "o" =>   "USNO-B1.0",
    "p" =>   "PPM",
    "q" =>   "UCAC-4",
    "r" =>   "UCAC-2",
    "s" =>   "USNO-B2.0",
    "t" =>   "PPMXL",
    "u" =>   "UCAC-3",
    "v" =>   "NOMAD",
    "w" =>   "CMC-14",
    "x" =>   "Hipparcos 2",
    "y" =>   "Hipparcos",
    "z" =>   "GSC (version unspecified)",
    "A" =>   "AC",
    "B" =>   "SAO 1984",
    "C" =>   "SAO",
    "D" =>   "AGK 3",
    "E" =>   "FK4",
    "F" =>   "ACRS",
    "G" =>   "Lick Gaspra Catalogue",
    "H" =>   "Ida93 Catalogue",
    "I" =>   "Perth 70",
    "J" =>   "COSMOS/UKST Southern Sky Catalogue",
    "K" =>   "Yale",
    "L" =>   "2MASS",
    "M" =>   "GSC-2.3",
    "N" =>   "SDSS-DR7",
    "O" =>   "SST-RC1",
    "P" =>   "MPOSC3",
    "Q" =>   "CMC-15",
    "R" =>   "SST-RC4",
    "S" =>   "URAT-1",
    "T" =>   "URAT-2",
    "U" =>   "Gaia-DR1",
    "V" =>   "Gaia-DR2",
    # "W" =>   "UCAC-5"
    "W" =>   "Gaia-DR3",
    "X" =>   "Gaia-EDR3",
    "Y" =>   "UCAC-5",
    "Z" =>   "ATLAS-2"
  )

@doc raw"""
    w8sveres17(row::NamedTuple)

Returns the statistical weight from Veres et al. (2017) corresponding to a row of a 
MPC-formatted file. 
""" 
function w8sveres17(row::NamedTuple)
    return w8sveres17(row.obscode, row.dt_utc_obs, row.catalog)
end

@doc raw"""
    w8sveres17(obscode::Union{Int,String}, dt_utc_obs::DateTime, catalog::String)

Returns the statistical weight from Veres et al. (2017) corresponding to the observatory with
code `obscode` in time `dt_utc_obs` and catalog `catalog`. 
"""
function w8sveres17(obscode::Union{Int,String}, dt_utc_obs::DateTime, catalog::String)
    # Unit weight (arcseconds)
    w = 1.0 
    # Table 2: epoch-dependent astrometric residuals
    if obscode == "703"
        return Date(dt_utc_obs) < Date(2014,1,1) ? w : 0.8w
    elseif obscode == "691"
        return Date(dt_utc_obs) < Date(2003,1,1) ? 0.6w : 0.5w
    elseif obscode == "644"
        return Date(dt_utc_obs) < Date(2003,9,1) ? 0.6w : 0.4w
    # Table 3: most active CCD asteroid observers
    elseif obscode ∈ ("704", "C51", "J75")
        return w
    elseif obscode == "G96"
        return 0.5w
    elseif obscode == "F51"
        return 0.2w
    elseif obscode ∈ ("G45", "608")
        return 0.6w
    elseif obscode == "699"
        return 0.8w
    elseif obscode ∈ ("D29", "E12")
        return 0.75w
    # Table 4:
    elseif obscode ∈ ("645", "673", "H01")
        return 0.3w
    elseif obscode ∈ ("J04", "K92", "K93", "Q63", "Q64", "V37", "W85", "W86", "W87", "K91", "E10", "F65") #Tenerife + Las Cumbres
        return 0.4w
    elseif obscode ∈ ("689", "950", "W84")
        return 0.5w
    #elseif obscode ∈ ("G83", "309") # Applies only to program code assigned to M. Micheli
    #    if catalog ∈ ("q", "t") # "q"=>"UCAC-4", "t"=>"PPMXL"
    #        return 0.3w
    #    elseif catalog ∈ ("U", "V") # Gaia-DR1, Gaia-DR2
    #        return 0.2w
    #    end
    elseif obscode ∈ ("Y28",)
        if catalog ∈ ("t", "U", "V")
            return 0.3w
        else
            return w
        end
    elseif obscode ∈ ("568",)
        if catalog ∈ ("o", "s") # "o"=>"USNO-B1.0", "s"=>"USNO-B2.0"
            return 0.5w
        elseif catalog ∈ ("U", "V") # Gaia DR1, DR2
            return 0.1w
        elseif catalog ∈ ("t",) #"t"=>"PPMXL"
            return 0.2w
        else
            return w
        end
    elseif obscode ∈ ("T09", "T12", "T14") && catalog ∈ ("U", "V") # Gaia DR1, DR2
        return 0.1w
    elseif catalog == " "
        return 1.5w
    elseif catalog != " "
        return w
    else
        return w
    end
end
