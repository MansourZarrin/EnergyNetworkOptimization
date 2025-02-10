using JuMP
using HiGHS

# =============== DATA SETS ===============
time_periods = 1:24
fossil_units = 1:2

# =============== PARAMETERS (EXAMPLE) ===============
fossil_capacity     = [80.0, 100.0]  # MW
fossil_gen_cost     = [45.0, 50.0]   # $/MWh
fossil_start_cost   = [200.0, 300.0] # $
min_up_time         = [2, 3]         # Hours
min_down_time       = [2, 2]         # Hours
ramp_limit          = [30.0, 30.0]   # MW/hour
emission_factor     = [0.7, 0.8]     # Tons/MWh
emission_cap        = 1000.0         # Tons
renewable_avail     = [Float64(rand(50:80)) for _ in time_periods]  # MW
demand              = [Float64(rand(90:120)) for _ in time_periods] # MW
battery_capacity    = 50.0           # MWh
charge_discharge_limit = 20.0        # MW
battery_efficiency  = 0.9            # Dimensionless
battery_cost        = 10.0           # $/MW
reserve_fraction    = 0.1            # Fraction of demand

# =============== MODEL ===============
model = Model(HiGHS.Optimizer)

# =============== DECISION VARIABLES ===============
@variable(model, 0 <= gen[f in fossil_units, t in time_periods] <= fossil_capacity[f])  # Fossil generation
@variable(model, on[f in fossil_units, t in time_periods], Bin)                         # Unit commitment
@variable(model, start_up[f in fossil_units, t in time_periods], Bin)                   # Start-up indicator
@variable(model, shut_down[f in fossil_units, t in time_periods], Bin)                  # Shut-down indicator
@variable(model, 0 <= ren[t in time_periods] <= renewable_avail[t])                     # Renewable generation
@variable(model, 0 <= charge[t in time_periods] <= charge_discharge_limit)              # Battery charging
@variable(model, 0 <= discharge[t in time_periods] <= charge_discharge_limit)           # Battery discharging
@variable(model, 0 <= stored[t in time_periods] <= battery_capacity)                    # Battery storage level
@variable(model, curtail[t in time_periods] >= 0)                                       # Renewable curtailment

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

# 2) Renewable availability and curtailment
@constraint(model, [t in time_periods],
    ren[t] + curtail[t] == renewable_avail[t]
)

# 3) Battery storage dynamics
@constraint(model, stored[1] == 0)  # Initial condition
@constraint(model, [t in 2:length(time_periods)],
    stored[t] == stored[t-1] + battery_efficiency * charge[t-1] - discharge[t-1] / battery_efficiency
)

# 4) Prevent over-discharge
@constraint(model, [t in time_periods],
    discharge[t] <= stored[t-1]
)

# 5) Start-up and shut-down tracking
@constraint(model, [f in fossil_units, t in 2:length(time_periods)],
    start_up[f,t] >= on[f,t] - on[f,t-1]
)
@constraint(model, [f in fossil_units, t in 2:length(time_periods)],
    shut_down[f,t] >= on[f,t-1] - on[f,t]
)

# 6) Minimum up/down times
for f in fossil_units
    # Minimum up time
    for t in 1:(length(time_periods) - min_up_time[f] + 1)
        @constraint(model, sum(on[f, τ] for τ in t:(t + min_up_time[f] - 1)) <= min_up_time[f] * on[f,t])
    end

    # Minimum down time
    for t in 1:(length(time_periods) - min_down_time[f] + 1)
        @constraint(model, sum(1 - on[f, τ] for τ in t:(t + min_down_time[f] - 1)) <= min_down_time[f] * (1 - on[f,t]))
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
    sum(on[f,t] * fossil_capacity[f] - gen[f,t] for f in fossil_units)
  + (charge_discharge_limit - discharge[t]) >= reserve_fraction * demand[t]
)

# 9) Emission cap
@constraint(model,
    sum(emission_factor[f] * gen[f,t] for f in fossil_units, t in time_periods) <= emission_cap
)

# 10) Link generation to unit commitment
@constraint(model, [f in fossil_units, t in time_periods],
    gen[f,t] <= on[f,t] * fossil_capacity[f]
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
        end
        println("  Renewables  =", round(value(ren[t]), digits=2), " MW",
                ", Curtailment =", round(value(curtail[t]), digits=2), " MW")
        println("  Battery     = Stored:", round(value(stored[t]), digits=2),
                ", Charge:", round(value(charge[t]), digits=2),
                ", Discharge:", round(value(discharge[t]), digits=2))
    end
else
    println("No optimal solution found. Status: ", termination_status(model))
end
