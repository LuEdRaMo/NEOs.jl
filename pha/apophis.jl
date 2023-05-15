using ArgParse, NEOs, PlanetaryEphemeris, Dates, TaylorIntegration, JLD2

# Load JPL ephemeris 
loadjpleph()

function parse_commandline()
    s = ArgParseSettings()

    # Program name (for usage & help screen)
    s.prog = "apophis.jl"  
    # Desciption (for help screen)
    s.description = "Propagates Apophis orbit via jet transport" 

    @add_arg_table! s begin
        "--jd0"
            help = "Initial date"
            arg_type = DateTime
            default = DateTime(2020, 12, 17)
        "--varorder"
            help = "Order of the jet transport perturbation" 
            arg_type = Int
            default = 5
        "--maxsteps"
            help = "Maximum number of steps during integration"
            arg_type = Int
            default = 10_000 
        "--nyears_bwd"
            help = "Years in backward integration"
            arg_type = Float64
            default = -18.0
        "--nyears_fwd"
            help = "Years in forward integration"
            arg_type = Float64
            default = 9.0 
        "--order"
            help = "Order of Taylor polynomials expansions during integration"
            arg_type = Int
            default = 25
        "--abstol"
            help = "Absolute tolerance"
            arg_type = Float64
            default = 1.0E-20
        "--parse_eqs"
            help = "Whether to use the taylorized method of jetcoeffs or not"
            arg_type = Bool
            default = true 
        "--ss_eph_file"
            help = "Path to local Solar System ephemeris file"
            arg_type = String 
            default = "./sseph343ast016_p31y_et.jld2"
    end

    s.epilog = """
        examples:\n
        \n
        # Multi-threaded\n
        julia-1.6 -t 4 --project apophis.jl --maxsteps 100 --nyears_bwd -0.02 --nyears_fwd 0.02 --parse_eqs true\n
        \n
        # Single-threaded\n
        julia-1.6 --project apophis.jl --maxsteps 100 --nyears_bwd -0.02 --nyears_fwd 0.02 --parse_eqs true\n
        \n
    """

    return parse_args(s)
end

function print_header(header::String)
    L = length(header)
    println(repeat("-", L))
    println(header)
    println(repeat("-", L))
end 

function main(dynamics::Function, maxsteps::Int, jd0_datetime::DateTime, nyears_bwd::T, nyears_fwd::T, 
              ss16asteph_et::TaylorInterpolant, order::Int, varorder::Int, abstol::T, parse_eqs::Bool) where {T <: Real}
    
    # Perturbation to nominal initial condition (Taylor1 jet transport)
    # vcat(fill(1e-8, 6), 1e-14, 1e-13) are the scaling factors for jet transport perturbation, 
    # these are needed to ensure expansion coefficients remain small. 
    # The magnitudes correspond to the typical order of magnitude of errors in 
    # position/velocity (1e-8), Yarkovsky (1e-13) and radiation pressure (1e-14)
    dq = NEOs.scaled_variables("δx", vcat(fill(1e-8, 6), 1e-14, 1e-13), order = varorder)

    # Initial conditions from Apophis JPL solution #197
    q00 = kmsec2auday(apophis_pv_197(datetime2et(jd0_datetime)))
    q0 = vcat(q00, 0.0, 0.0) .+ dq

    # Initial date (in julian days)
    jd0 = datetime2julian(jd0_datetime)

    print_header("Integrator warmup")
    sol = NEOs.propagate(dynamics, 1, jd0, nyears_fwd, ss16asteph_et, q0, Val(true); 
                         order = order, abstol = abstol, parse_eqs = parse_eqs)
    
    print_header("Main integration")
    tmax = nyears_bwd*yr 
    println("• Initial time of integration: ", string(jd0_datetime))
    println("• Final time of integration: ", julian2datetime(jd0 + tmax))

    sol = NEOs.propagate(dynamics, maxsteps, jd0, nyears_bwd, ss16asteph_et, q0, Val(true); 
                         order = order, abstol = abstol, parse_eqs = parse_eqs)
    save2jldandcheck("Apophis_bwd", (asteph = sol,))

    tmax = nyears_fwd*yr 
    println("• Initial time of integration: ", string(jd0_datetime))
    println("• Final time of integration: ", julian2datetime(jd0 + tmax))

    sol = NEOs.propagate(dynamics, maxsteps, jd0, nyears_fwd, ss16asteph_et, q0, Val(true), 
                         order = order, abstol = abstol, parse_eqs = parse_eqs)
    save2jldandcheck("Apophis_fwd", (asteph = sol,))
    
    nothing 
    
end 

function main()

    # Parse arguments from commandline 
    parsed_args = parse_commandline()
    
    print_header("Asteroid Apophis")
    print_header("General parameters")

    # Number of threads 
    N_threads = Threads.nthreads()
    println("• Number of threads: ", N_threads)

    # Dynamical function 
    if N_threads == 1
        dynamics = RNp1BP_pN_A_J23E_J2S_ng_eph!
    else 
        dynamics = RNp1BP_pN_A_J23E_J2S_ng_eph_threads!
    end 
    println("• Dynamical function: ", dynamics)

    # Maximum number of steps 
    maxsteps = parsed_args["maxsteps"]
    println("• Maximum number of steps: ", maxsteps)

    # Initial date 
    jd0_datetime = parsed_args["jd0"]

    # Number of years in backward integration
    nyears_bwd = parsed_args["nyears_bwd"]

    # Number of years in forward integration
    nyears_fwd = parsed_args["nyears_fwd"]

    # Solar system ephemeris 
    print("• Loading Solar System ephemeris... ")
    ss16asteph_et = JLD2.load(parsed_args["ss_eph_file"], "ss16ast_eph")
    println("Done")

    # Order of Taylor polynomials
    order = parsed_args["order"]
    println("• Order of Taylor polynomials: ", order)

    # Order of jet transport perturbation
    varorder = parsed_args["varorder"]
    println("• Order of jet transport perturbation: ", varorder)

    # Absolute tolerance
    abstol = parsed_args["abstol"]
    println("• Absolute tolerance: ", abstol)

    # Wheter to use @taylorize or not 
    parse_eqs = parsed_args["parse_eqs"]
    println("• Use @taylorize: ", parse_eqs)

    main(dynamics, maxsteps, jd0_datetime,  nyears_bwd, nyears_fwd, ss16asteph_et, 
         order, varorder, abstol, parse_eqs)
end 

main()
