#Multi-threaded:
#JULIA_NUM_THREADS=8 julia --project=@. main.jl
#Single-threaded:
#julia --project=@. main.jl
using Apophis
using Dates

@show Threads.nthreads()

#script parameters (TODO: use ArgParse.jl instead)
const objname = "Apophis"
const newtoniter = 10
const maxsteps = 10000
const nyears = 24.0
const jt = true
const dense = true#false
# const dynamics = RNp1BP_pN_A_J23E_J2S_ng_eph!
const dynamics = RNp1BP_pN_A_J23E_J2S_ng_eph_threads!
const t0 = datetime2julian(DateTime(2008,9,24,0,0,0)) #starting time of integration
@show t0 == 2454733.5

#integrator warmup
propagate(objname, dynamics, 1, newtoniter, t0, nyears, output=false, jt=jt, dense=dense)
println("*** Finished warmup")

propagate(objname, dynamics, 10, newtoniter, t0, nyears, jt=jt, dense=dense)
println("*** Finished 2nd warmup")

#root-finding methods warmup (integrate until first root-finding event):
# propagate(objname, dynamics, 50, newtoniter, t0, nyears, jt=jt, dense=dense)
# println("*** Finished root-finding warmup")

#propagate(objname, dynamics, 100, newtoniter, t0, nyears, jt=jt, dense=dense)
#println("*** Finished root-finding test: several roots")

#Full jet transport integration until ~2038: about 8,000 steps
# propagate(objname, dynamics, 8000, newtoniter, t0, nyears, jt=jt, dense=dense)
# println("*** Finished full jet transport integration")
