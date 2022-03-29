#numerator of asteroid radial velocity wrt Earth
function rvelea(dx, x, params, t)
    jd0 = params[4] # Julian date of start time
    dsj2k = t+(jd0-JD_J2000) # days since J2000.0 = 2.451545e6
    ss16asteph_t = evaleph(params[1], dsj2k, x[1]) # params[2](t)*one(q[1]) #ss16asteph(t)
    N = params[6]
    xe = ss16asteph_t[nbodyind(N-1,ea)]
    return true, (x[1]-xe[1])*(x[4]-xe[4]) + (x[2]-xe[2])*(x[5]-xe[5]) + (x[3]-xe[3])*(x[6]-xe[6])
end

function loadeph(ss16asteph_::TaylorInterpolant, μ::Vector)
    # read Solar System ephemeris (Sun+8 planets+Moon+Pluto+16 main belt asteroids)
    ss16asteph_t0 = (ss16asteph_.t0 ./ daysec)
    ss16asteph_t = (ss16asteph_.t ./ daysec)
    ephord = ss16asteph_.x[1].order
    ss16asteph_x = map(x->x(Taylor1(ephord)*daysec), ss16asteph_.x)
    ss16asteph = TaylorInterpolant(ss16asteph_t0, ss16asteph_t, ss16asteph_x)
    #compute point-mass Newtonian accelerations from ephemeris: all bodies except asteroid
    # accelerations of "everybody else" are needed when evaluating asteroid post-Newtonian acceleration
    Nm1 = (size(ss16asteph_x)[2]-13) ÷ 6
    acc_eph = TaylorInterpolant(ss16asteph.t0, ss16asteph.t, Matrix{eltype(ss16asteph.x)}(undef, length(ss16asteph.t)-1, 3Nm1))
    newtonianNb_Potential = TaylorInterpolant(ss16asteph.t0, ss16asteph.t, Matrix{eltype(ss16asteph.x)}(undef, length(ss16asteph.t)-1, Nm1))
    fill!(acc_eph.x, zero(ss16asteph.x[1]))
    fill!(newtonianNb_Potential.x, zero(ss16asteph.x[1]))
    _1_to_Nm1 = Base.OneTo(Nm1) # iterator over all bodies except asteroid
    for j in _1_to_Nm1
        for i in _1_to_Nm1
            # i == j && continue
            if i == j
            else
                X_ij = ss16asteph.x[:,3i-2] .- ss16asteph.x[:,3j-2]
                Y_ij = ss16asteph.x[:,3i-1] .- ss16asteph.x[:,3j-1]
                Z_ij = ss16asteph.x[:,3i  ] .- ss16asteph.x[:,3j  ]
                r_p2_ij = ( (X_ij.^2) .+ (Y_ij.^2) ) .+ (Z_ij.^2)
                r_ij = sqrt.(r_p2_ij)
                newtonianNb_Potential.x[:,j] .+= (μ[i]./r_ij)
            end #if i != j
        end #for, i
        acc_eph.x[:,3j-2] .= differentiate.(ss16asteph.x[:,3(Nm1+j)-2])
        acc_eph.x[:,3j-1] .= differentiate.(ss16asteph.x[:,3(Nm1+j)-1])
        acc_eph.x[:,3j  ] .= differentiate.(ss16asteph.x[:,3(Nm1+j)  ])
    end #for, j
    return ss16asteph, acc_eph, newtonianNb_Potential
end

function save2jldandcheck(objname, sol)
    outfilename = string(objname, "_jt.jld")
    return __save2jldandcheck(outfilename, sol)
end

function __save2jldandcheck(outfilename, sol)
    println("Saving solution to file: $outfilename")
    jldopen(outfilename, "w") do file
        #loop over solution variables
        for ind in eachindex(sol)
            varname = string(ind)
            println("Saving variable: ", varname)
            write(file, varname, sol[ind])
        end
    end
    println("Checking that all variables were saved correctly...")
    #loop over solution variables
    for ind in eachindex(sol)
        varname = string(ind)
        #read varname from files and assign recovered variable to recovered_sol_i
        recovered_sol_i = JLD.load(outfilename, varname)
        #check that varname was recovered succesfully
        @show recovered_sol_i == sol[ind]
    end
    println("Saved solution")
    return outfilename
end

function taylor_minimum(pol::Taylor1{T}, x0::T; niters::Int=10) where {T<:Real}
    dpol = differentiate(pol)
    dpol2 = differentiate(dpol)
    xnewton::T = x0
    #@show xnewton
    for i in 1:niters
        xnewton -= dpol(xnewton)/dpol2(xnewton)
        #@show xnewton, dpol(xnewton)
    end
    return xnewton
end

function taylor_roots(pol::Taylor1{T}, x0::T; niters::Int=10) where {T<:Real}
    dpol = differentiate(pol)
    xnewton::T = x0
    #@show xnewton
    for i in 1:niters
        xnewton -= pol(xnewton)/dpol(xnewton)
        #@show xnewton, pol(xnewton)
    end
    return xnewton
end

function scaling(a::Taylor1{Taylor1{T}}, c::T) where {T<:Real}
    x = c*Taylor1( Taylor1(a.order).coeffs*one(a[0]) )
    return a(x)
end

function propagate(objname::String, dynamics::Function, maxsteps::Int, jd0::T,
        tspan::T, ephfile::String; kwargs...) where {T<:Real}
    # load ephemeris
    ss16asteph_et = JLD.load(ephfile, "ss16ast_eph")
    propagate(objname::String, dynamics::Function, maxsteps::Int, jd0::T, tspan::T, ss16asteph_et; kwargs...)
end

for V in (:Val{true}, :Val{false})
    @eval begin
        function propagate(objname::String, dynamics::Function, maxsteps::Int, jd0::T,
            tspan::T, ss16asteph_et::TaylorInterpolant, ::$V; output::Bool=true, newtoniter::Int=10,
            q0::Vector=initialcond(), radarobsfile::String="",
            opticalobsfile::String="", quadmath::Bool=false,
            debias_table::String="2018", μ_ast::Vector=μ_ast343_DE430[1:end],
            lyap::Bool=false, order::Int=order, abstol::T=abstol, tord::Int=10,
            niter::Int=5) where {T<:Real}
            # get asteroid initial conditions
            @assert length(q0) == 8
            @show q0
            @show jd0, jd0-JD_J2000
            # Number of bodies
            Nm1 = (size(ss16asteph_et.x)[2]-13) ÷ 6 # number of massive bodies
            @show Nm1
            N = Nm1 + 1 # number of bodies, including NEA
            # vector of G*m values
            μ = vcat(μ_DE430[1:11], μ_ast[1:Nm1-11], zero(μ_DE430[1]))
        
            # check: number of SS bodies (N) in ephemeris must be equal to length of GM vector (μ)
            @assert N == length(μ) "Total number of bodies in ephemeris must be equal to length of GM vector μ"
        
            # process ephemeris (switch from km,km/s units to au,au/day)
            # compute Newtonian accelerations and potentials (used in post-Newtonian accelerations)
            ss16asteph_auday, acc_eph, newtonianNb_Potential = loadeph(ss16asteph_et, μ)
        
            # interaction matrix with flattened bodies
            UJ_interaction = fill(false, N)
            # UJ_interaction[su] = true
            UJ_interaction[ea] = true
            # UJ_interaction[mo] = true
            params = (ss16asteph_auday, acc_eph, newtonianNb_Potential, jd0, UJ_interaction, N, μ)
        
            if quadmath
                _q0 = one(Float128)*q0
                _t0 = zero(Float128)
                _abstol = Float128(abstol)
                _ss16asteph = TaylorInterpolant(Float128(ss16asteph_auday.t0), Float128.(ss16asteph_auday.t), map(x->Taylor1(Float128.(x.coeffs)), ss16asteph_auday.x))
                _acc_eph = TaylorInterpolant(Float128(acc_eph.t0), Float128.(acc_eph.t), map(x->Taylor1(Float128.(x.coeffs)), acc_eph.x))
                _newtonianNb_Potential = TaylorInterpolant(Float128(newtonianNb_Potential.t0), Float128.(newtonianNb_Potential.t), map(x->Taylor1(Float128.(x.coeffs)), newtonianNb_Potential.x))
                _params = (_ss16asteph, _acc_eph, _newtonianNb_Potential, Float128(jd0), UJ_interaction, N, μ)
            else
                _q0 = q0
                _t0 = zero(Float64)
                _abstol = abstol
                _params = params
            end
        
            @show _tmax = _t0+tspan*yr #final time of integration
        
            # propagate orbit
            if $V == Val{true}
                @time interp = apophisinteg(dynamics, _q0, _t0, _tmax, order, _abstol, Val(true), _params; maxsteps=maxsteps)
                if quadmath
                    asteph_t0 = Float64(jd0-JD_J2000) # days since J2000 until initial integration time
                    asteph_t = Float64.(interp.t[:])
                    asteph_x = convert(Array{Taylor1{eltype(q0)}}, interp.x[:,:])
                    asteph = TaylorInterpolant(asteph_t0, asteph_t, asteph_x)
                    sol = (asteph=asteph,
                    )
                else
                    asteph_t0 = (jd0-JD_J2000) # days since J2000 until initial integration time
                    asteph_t = interp.t[:]
                    asteph_x = interp.x[:,:]
                    asteph = TaylorInterpolant(asteph_t0, asteph_t, asteph_x)
                    sol = (asteph=asteph,
                    )
                end
            elseif lyap
                @time sol_objs = lyap_apophisinteg(dynamics, _q0, _t0, _tmax, order, _abstol, _params; maxsteps=maxsteps)
                sol = (
                    tv=convert(Array{eltype(q0)}, sol_objs[1][:]),
                    xv=convert(Array{eltype(q0)}, sol_objs[2][:,:]),
                    λv=convert(Array{eltype(q0)}, sol_objs[3][:,:])
                )
            else
                @time sol_objs = apophisinteg(dynamics, rvelea, _q0, _t0, _tmax, order, _abstol, Val(true), _params; maxsteps=maxsteps, newtoniter=newtoniter)
                asteph_t0 = (_params[4]-JD_J2000) # days since J2000 until initial integration time
                asteph_t = sol_objs[1].t[:]
                asteph_x = sol_objs[1].x[:,:]
                asteph = TaylorInterpolant(asteph_t0, asteph_t, asteph_x)
                sol = (
                    asteph=asteph,
                    tv = asteph_t0 .+ asteph_t,
                    xv = asteph_x(),
                    tvS1=convert(Array{eltype(q0)}, sol_objs[2][:]),
                    xvS1=convert(Array{eltype(q0)}, sol_objs[3][:,:]),
                    gvS1=convert(Array{eltype(q0)}, sol_objs[4][:])
                )
            end
        
            #write solution and predicted values of observations (if requested) to .jld files
            if output
                outfilename = save2jldandcheck(objname, sol)
                # if requested by user, calculate computed (i.e., predicted) values of observations
                if !lyap # don't compute observation ephemeris when "in Lyapunov spectra mode"
                    try
                        furnsh(
                            joinpath(artifact"naif0012", "naif0012.tls"), # load leapseconds kernel
                            joinpath(artifact"de430", "de430_1850-2150.bsp"), # at least one SPK file must be loaded to read .tls file
                        )
                        if radarobsfile != ""
                            println("compute_radar_obs")
                            @time compute_radar_obs("deldop_"*basename(radarobsfile)*".jld", radarobsfile, asteph, ss16asteph_et, tord=tord, niter=niter)
                        end
                        if opticalobsfile != ""
                            println("compute_optical_obs")
                            @time compute_optical_obs("radec_"*basename(opticalobsfile)*".jld", opticalobsfile, asteph, ss16asteph_et, debias_table=debias_table, niter=niter)
                        end
                    catch e
                        @error "Unable to compute observation residuals" exception=(e, catch_backtrace())
                    end
                end
            end
        
            return sol
        end    
    end
end
function propagate(objname::String, dynamics::Function, maxsteps::Int, jd0::T,
    tspan::T, ss16asteph_et::TaylorInterpolant; output::Bool=true, newtoniter::Int=10,
    q0::Vector=initialcond(), radarobsfile::String="",
    opticalobsfile::String="", quadmath::Bool=false,
    debias_table::String="2018", μ_ast::Vector=μ_ast343_DE430[1:end],
    lyap::Bool=false, order::Int=order, abstol::T=abstol, tord::Int=10,
    niter::Int=5) where {T<:Real}
    return propagate(objname, dynamics, maxsteps, jd0, tspan, ss16asteph_et, Val(false);
    output, newtoniter, q0, radarobsfile, opticalobsfile, quadmath, debias_table, μ_ast,
    lyap, order, abstol, tord, niter)
end

function compute_radar_obs(outfilename::String, radarobsfile::String,
        asteph::TaylorInterpolant, ss16asteph::TaylorInterpolant; tc::Real=1.0,
        autodiff::Bool=true, tord::Int=10, niter::Int=5)
    @assert isfile(radarobsfile) "Cannot open file: $radarobsfile"
    Nm1 = (size(ss16asteph.x)[2]-13) ÷ 6
    N = Nm1 + 1
    # TODO: check that first and last observation times are within interpolation interval
    # asteroid/small-body
    # Change t, x, v units, resp., from days, au, au/day to sec, km, km/sec
    asteph_ord = asteph.x[1].order
    asteph_t0 = asteph.t0*daysec
    asteph_t = asteph.t*daysec
    asteph_r = au*map(x->x(Taylor1(asteph_ord)/daysec), asteph.x[:,1:3])
    asteph_v = (au/daysec)*map(x->x(Taylor1(asteph_ord)/daysec), asteph.x[:,4:6])
    asteph_x = hcat(asteph_r, asteph_v)
    asteph_et = TaylorInterpolant(asteph_t0, asteph_t, asteph_x)
    # Sun (su=1)
    # Change x, v units, resp., from au, au/day to km, km/sec
    sseph_t0 = ss16asteph.t0
    sseph_t = ss16asteph.t
    sseph_x = ss16asteph.x
    sun_r = au*sseph_x[:,nbodyind(Nm1,su)[1:3]]
    sun_v = (au/daysec)*sseph_x[:,nbodyind(Nm1,su)[4:6]]
    sun_x = hcat(sun_r, sun_v)
    sun_et = TaylorInterpolant(sseph_t0, sseph_t, sun_x)
    # Earth (ea=4)
    # Change x, v units, resp., from au, au/day to km, km/sec
    earth_r = au*sseph_x[:,nbodyind(Nm1,ea)[1:3]]
    earth_v = (au/daysec)*sseph_x[:,nbodyind(Nm1,ea)[4:6]]
    earth_x = hcat(earth_r, earth_v)
    earth_et = TaylorInterpolant(sseph_t0, sseph_t, earth_x)
    # construct DataFrame with delay/doppler data from JPL radar obs file, including delay/doppler ephemeris (i.e., predicted values)
    deldop_table_jld = delay_doppler(radarobsfile, niter, xve=earth_et, xvs=sun_et, xva=asteph_et, tc=tc, tord=tord, autodiff=autodiff)
    #save data to file
    println("Saving data to file: $outfilename")
    jldopen(outfilename, "w") do file
        addrequire(file, DataFrames)
        addrequire(file, TaylorSeries)
        # write variables to jld file
        JLD.write(file, "deldop_table", deldop_table_jld)
    end
    return nothing
end

function compute_optical_obs(outfilename::String, opticalobsfile::String,
        asteph, ss16asteph; debias_table::String="2018", niter::Int=5)
    @assert isfile(opticalobsfile) "Cannot open file: $opticalobsfile"
    Nm1 = (size(ss16asteph.x)[2]-13) ÷ 6
    N = Nm1 + 1
    # TODO: check that first and last observation times are within interpolation interval
    function asteph_et(et)
        return auday2kmsec(asteph(et/daysec)[1:6])
    end
    function earth_et(et)
        return auday2kmsec(ss16asteph(et)[union(3*4-2:3*4,3*(N-1+4)-2:3*(N-1+4))])
    end
    function sun_et(et)
        return auday2kmsec(ss16asteph(et)[union(3*1-2:3*1,3*(N-1+1)-2:3*(N-1+1))])
    end
    # construct DataFrame with ra/dec data from MPC optical obs file, including ra/dec ephemeris (i.e., predicted values)
    radec_table_jdb = radec_table(opticalobsfile, niter, xve=earth_et, xvs=sun_et, xva=asteph_et, debias_table=debias_table)
    #save data to file
    println("Saving data to file: $outfilename")
    jldopen(outfilename, "w") do file
        addrequire(file, DataFrames)
        addrequire(file, TaylorSeries)
        # write variables to jld file
        JLD.write(file, "radec_table", radec_table_jdb)
    end
    return nothing
end
