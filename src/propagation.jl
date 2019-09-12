#numerator of Apophis radial velocity wrt Earth
function rvelea(dx, x, params, t)
    ss16asteph_t = params[1](t) #ss16asteph(t)
    xe = ss16asteph_t[union(3ea-2:3ea,3(N-1+ea)-2:3(N-1+ea))]
    return (x[1]-xe[1])*(x[4]-xe[4]) + (x[2]-xe[2])*(x[5]-xe[5]) + (x[3]-xe[3])*(x[6]-xe[6])
end

function propagate(objname::String, datafile::String, dynamics::Function, maxsteps::Int,
    newtoniter::Int, t0::T, tspan::T; output::Bool=true, radarobs::Bool=true,
    jt::Bool=true, dense::Bool=false) where {T<:Real}

    # read Solar System ephemeris (Sun+8 planets+Moon+Pluto+16 main belt asteroids)
    ss16asteph = load(joinpath(jplephpath, "ss16ast343_eph.jld"), "ss16ast_eph")
    #compute point-mass Newtonian accelerations from ephemeris: all bodies except Apophis
    # accelerations of "everybody else" are needed when evaluating Apophis post-Newtonian acceleration
    Nm1 = N-1
    acc_eph = TaylorInterpolant(ss16asteph.t, Matrix{eltype(ss16asteph.x)}(undef, length(ss16asteph.t)-1, 3Nm1))
    fill!(acc_eph.x, zero(ss16asteph.x[1]))
    _1_to_Nm1 = Base.OneTo(Nm1) # iterator over all bodies except Apophis
    for j in _1_to_Nm1
        for i in _1_to_Nm1
            # i == j && continue
            if i == j
            else
                X_ij = ss16asteph.x[:,3i-2] .- ss16asteph.x[:,3j-2]
                Y_ij = ss16asteph.x[:,3i-1] .- ss16asteph.x[:,3j-1]
                Z_ij = ss16asteph.x[:,3i  ] .- ss16asteph.x[:,3j  ]
                r_p2_ij = ( (X_ij.^2) .+ (Y_ij.^2) ) .+ (Z_ij.^2)
                r_p3d2_ij = r_p2_ij.^1.5
                newtonianCoeff_ij =  μ[i]./r_p3d2_ij
                acc_eph.x[:,3j-2] .+= (X_ij.*newtonianCoeff_ij)
                acc_eph.x[:,3j-1] .+= (Y_ij.*newtonianCoeff_ij)
                acc_eph.x[:,3j  ] .+= (Z_ij.*newtonianCoeff_ij)
            end #if i != j
        end #for, i
    end #for, j

    params = (ss16asteph, acc_eph)

    # get asteroid initial conditions
    __q0 = initialcond()

    if jt
        #construct jet transport initial condition as Vector{Taylor1{Float64}} from `__q0`
        q0T1 = Taylor1.(__q0,varorder)
        q0T1[1:end-1] = Taylor1.(__q0[1:end-1],varorder)
        q0T1[end] = Taylor1([__q0[end],1e-14],varorder) #note the 1e-14!!!
        q0 = q0T1
    else
        q0 = __q0
    end

    @show tmax = t0+tspan*yr #final time of integration

    # do integration
    if dense
        @time interp = taylorinteg(dynamics, q0, t0, tmax, order, abstol, params; maxsteps=maxsteps, dense=dense);
        sol = (t=interp.t[:], x=interp.x[:,:])
    else
        if radarobs
            # read object radar astrometry from JPL date
            radar_data_jpl = process_radar_data_jpl(datafile)
            #construct vector of observation times (UTC) > t0
            tv_jpl_utc = UTCEpoch.([x.utcepoch for x in radar_data_jpl])
            # convert to TDB
            tv_jpl_tdb = TDBEpoch.(tv_jpl_utc)
            # date/time to Julian date
            tv_jpl_tdb_julian =  map(x->x.Δt, julian.(tv_jpl_tdb))
            # construct time range variable with t0 and observation times > t0, removing repeated values
            tv = union(t0, tv_jpl_tdb_julian[tv_jpl_tdb_julian .> t0])
            @show all(diff(tv) .> 0)
            @time sol_objs = taylorinteg(dynamics, rvelea, q0, tv, order, abstol, params; maxsteps=maxsteps, newtoniter=newtoniter);
            tup_names = (:xv1, :tvS1, :xvS1, :gvS1)
            sol = NamedTuple{tup_names}(sol_objs)
        else
            @time sol_objs = taylorinteg(dynamics, rvelea, q0, t0, tmax, order, abstol, params; maxsteps=maxsteps, newtoniter=newtoniter);
            tup_names = (:tv1, :xv1, :tvS1, :xvS1, :gvS1)
            sol = NamedTuple{tup_names}(sol_objs)
        end
    end

    #write solution to .jld files
    if output
        filename = string(objname, "_jt.jld")
        println("Saving solution to file: $filename")
        #first, deal with `tv_jpl_integ`
        jldopen(filename, "w") do file
            if dense
                addrequire(file, TaylorSeries)
                addrequire(file, TaylorIntegration)
            end
            if radarobs
                println("Saving variable: tv1")
                write(file, "tv1", tv)
            end
            #loop over variables
            for ind in eachindex(sol)
                varname = string(ind)
                println("Saving variable: ", varname)
                write(file, varname, sol[ind])
            end
        end
        #check that tv_jpl_integ was recovered succesfully
        println("Checking that all variables were saved correctly...")
        if radarobs
            recovered_tv_jpl_integ = load(filename, "tv1")
            @show recovered_tv_jpl_integ == tv
        end
        #loop over rest of variables
        for ind in eachindex(sol)
            varname = string(ind)
            #read varname from files and assign recovered variable to recovered_sol_i
            recovered_sol_i = load(filename, varname)
            #check that varname was recovered succesfully
            @show recovered_sol_i == sol[ind]
        end
        println("Saved solution")
    end
    return nothing
end

function testjetcoeffs()
    global ss16asteph = load(joinpath(jplephpath, "ss16ast343_eph.jld"), "ss16ast_eph")
    global acc_eph = TaylorInterpolant(ss16asteph.t, differentiate.(ss16asteph.x[:,3(N-1)+1:6(N-1)]))
    q0 = initialcond()
    t0 = datetime2julian(DateTime(2008,9,24))
    tT = t0 + Taylor1(order)
    q0T = Taylor1.(q0, order)
    dq0T = similar(q0T)
    xaux = similar(q0T)
    q0T2 = Taylor1.(q0, order)
    dq0T2 = similar(q0T)
    @show methods(TaylorIntegration.jetcoeffs!)
    @time TaylorIntegration.jetcoeffs!(RNp1BP_pN_A_J23E_J2S_ng_eph!, tT, q0T, dq0T, xaux)
    @time TaylorIntegration.jetcoeffs!(Val(RNp1BP_pN_A_J23E_J2S_ng_eph!), tT, q0T2, dq0T2)

    @show q0T
    @show q0T2
    @show norm(q0T-q0T2, Inf)
    @show norm(dq0T-dq0T2, Inf)
end