using JuMP
using HiGHS

# =============== DATA SETS ===============
time_periods = 1:24
fossil_units = 1:2

# =============== PARAMETERS (EXAMPLE) ===============
fossil_capacity     = [80.0, 100.0]
fossil_gen_cost     = [45.0, 50.0]
fossil_start_cost   = [200.0, 300.0]
min_up_time         = [2, 3]
min_down_time       = [2, 2]
ramp_limit          = [30.0, 30.0]
emission_factor     = [0.7, 0.8]
emission_cap        = 1000.0

renewable_avail     = [rand(50:80) for _ in time_periods]   # MW
demand              = [rand(90:120) for _ in time_periods]  # MW
battery_capacity    = 50.0
charge_discharge_limit = 20.0
battery_efficiency  = 0.9
battery_cost        = 10.0
reserve_fraction    = 0.1

# =============== MODEL ===============
model = Model(HiGHS.Optimizer)

# =============== DECISION VARIABLES ===============
@variable(model, 0 <= gen[f in fossil_units, t in time_periods])
@variable(model, on[f in fossil_units, t in time_periods], Bin)
@variable(model, start_up[f in fossil_units, t in time_periods], Bin)
@variable(model, 0 <= ren[t in time_periods] <= maximum(renewable_avail))
@variable(model, 0 <= charge[t in time_periods] <= charge_discharge_limit)
@variable(model, 0 <= discharge[t in time_periods] <= charge_discharge_limit)
@variable(model, 0 <= stored[t in time_periods] <= battery_capacity)

# =============== OBJECTIVE ===============
@objective(model, Min,
    sum(fossil_gen_cost[f] * gen[f,t] for f in fossil_units, t in time_periods)
  + sum(fossil_start_cost[f] * start_up[f,t] for f in fossil_units, t in time_periods)
  + battery_cost * sum(charge[t] + discharge[t] for t in time_periods)
)

# =============== CONSTRAINTS ===============

# 1) Demand balance
@constraint(model, [t in time_periods],
    sum(gen[f,t] for f in fossil_units) + ren[t] + discharge[t] - charge[t] == demand[t]
)

# 2) Fossil capacity
@constraint(model, [f in fossil_units, t in time_periods],
    gen[f,t] <= on[f,t] * fossil_capacity[f]
)

# 3) Renewable limit
@constraint(model, [t in time_periods], ren[t] <= renewable_avail[t])

# 4) Battery storage dynamics
@constraint(model, stored[1] == 0)
@constraint(model, [t in 2:length(time_periods)],
    stored[t] == stored[t-1] + battery_efficiency*charge[t-1] - discharge[t-1]/battery_efficiency
)

# 5) Start-up tracking
@constraint(model, [f in fossil_units],
    start_up[f,1] >= on[f,1]
)
@constraint(model, [f in fossil_units, t in 2:length(time_periods)],
    start_up[f,t] >= on[f,t] - on[f,t-1]
)

# 6) Minimum up/down times
for f in fossil_units
    # If on[f,1] = 1, must stay ON for min_up_time[f]-1 hours
    if min_up_time[f] > 1
        for tau in 2 : min(1 + min_up_time[f] - 1, last(time_periods))
            @constraint(model, on[f,1] <= on[f,tau])
        end
    end
    for t in 2:length(time_periods)
        for tau in t+1 : min(t + min_up_time[f] - 1, last(time_periods))
            @constraint(model, on[f,t] - on[f,t-1] <= on[f,tau])
        end
        for tau in t+1 : min(t + min_down_time[f] - 1, last(time_periods))
            @constraint(model, on[f,t-1] - on[f,t] <= 1 - on[f,tau])
        end
    end
end

# 7) Ramp constraints
for f in fossil_units
    for t in 2:length(time_periods)
        @constraint(model, gen[f,t] - gen[f,t-1] <= ramp_limit[f])
        @constraint(model, gen[f,t-1] - gen[f,t] <= ramp_limit[f])
    end
end

# 8) Spinning reserve
@constraint(model, [t in time_periods],
    sum(on[f,t]*fossil_capacity[f] - gen[f,t] for f in fossil_units)
  + (charge_discharge_limit - discharge[t]) >= reserve_fraction * demand[t]
)

# 9) Emission cap
@constraint(model,
    sum(emission_factor[f]*gen[f,t] for f in fossil_units, t in time_periods) <= emission_cap
)

# =============== SOLVE ===============
optimize!(model)

# =============== DISPLAY RESULTS ===============
println("Status: ", termination_status(model))
if termination_status(model) == MOI.OPTIMAL
    println("Optimal Objective Value: ", objective_value(model))
    for t in time_periods
        println("\nHour $t:")
        for f in fossil_units
            println("  FossilUnit$f: On =", value(on[f,t]),
                    ", Gen =", round(value(gen[f,t]), digits=2), " MW")
        end  # End of inner loop (fossil_units)
        println("  Renewables  =", round(value(ren[t]), digits=2), " MW")
        println("  Battery     = Stored:", round(value(stored[t]), digits=2),
                ", Charge:", round(value(charge[t]), digits=2),
                ", Discharge:", round(value(discharge[t]), digits=2))
    end  # End of outer loop (time_periods)
else
    println("No optimal solution found. Status: ", termination_status(model))
end  # End of if-else block
