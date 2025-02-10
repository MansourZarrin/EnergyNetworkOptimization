using JuMP
using HiGHS

# --- Sets and Indices ---
time_periods = 1:24
fossil_units = 1:2

# --- Model Parameters (illustrative only) ---
fossil_capacity     = [80, 100]      # MW capacity for each fossil unit
fossil_gen_cost     = [45.0, 50.0]   # $/MWh generation cost for each unit
fossil_start_cost   = [200.0, 300.0] # $ cost to start each unit
min_up_time         = [2, 3]         # hours a unit must stay ON once started
min_down_time       = [2, 2]         # hours a unit must stay OFF once stopped
ramp_limit          = [30.0, 30.0]   # MW/hour max ramp up/down

renewable_avail = [rand(50:80) for _ in time_periods]  # MW available renewable
renewable_cost  = 0.0                                  # $/MWh for renewables (assume free)
demand          = [rand(90:120) for _ in time_periods] # MW demand

emission_factor_fossil = [0.7, 0.8]  # tonCO2/MWh
emission_cap           = 1000.0      # total tonCO2 allowed

battery_capacity       = 50.0
charge_discharge_limit = 20.0
battery_efficiency     = 0.9
battery_cost           = 10.0        # $/MWh for charging/discharging

reserve_fraction       = 0.1         # 10% spinning reserve

# --- Model ---
model = Model(HiGHS.Optimizer)

# --- Decision Variables ---
@variable(model, 0 <= gen[f in fossil_units, t in time_periods])
@variable(model, on[f in fossil_units, t in time_periods], Bin)
@variable(model, start[f in fossil_units, t in time_periods], Bin)

@variable(model, 0 <= ren[t in time_periods] <= maximum(renewable_avail))
@variable(model, 0 <= charge[t in time_periods] <= charge_discharge_limit)
@variable(model, 0 <= discharge[t in time_periods] <= charge_discharge_limit)
@variable(model, 0 <= stored[t in time_periods] <= battery_capacity)

# --- Objective: generation cost + start-up cost + battery cost ---
@objective(model, Min, 
    sum(fossil_gen_cost[f]*gen[f,t] for f in fossil_units, t in time_periods) +
    sum(fossil_start_cost[f]*start[f,t] for f in fossil_units, t in time_periods) +
    battery_cost * sum(charge[t] + discharge[t] for t in time_periods)
)

# --- Constraints ---

# 1) Demand balance
@constraint(model, [t in time_periods], 
    sum(gen[f,t] for f in fossil_units) + ren[t] + discharge[t] - charge[t] == demand[t]
)

# 2) Capacity constraints
@constraint(model, [f in fossil_units, t in time_periods], 
    gen[f,t] <= on[f,t] * fossil_capacity[f]
)
@constraint(model, [t in time_periods],
    ren[t] <= renewable_avail[t]
)

# 3) Battery storage dynamics
@constraint(model, stored[1] == 0)  # assume empty at start
@constraint(model, [t in 2:length(time_periods)],
    stored[t] == stored[t-1] + battery_efficiency*charge[t-1] - discharge[t-1]/battery_efficiency
)

# 4) Start-up tracking: start[f,t] >= on[f,t] - on[f,t-1]
for f in fossil_units
    @constraint(model, on[f,1] - 0 <= start[f,1])  # initial start if ON in first period
    for t in 2:length(time_periods)
        @constraint(model, start[f,t] >= on[f,t] - on[f,t-1])
    end
end

# 5) Minimum Up/Down times
#   If a unit turns on at time t, it must stay on for next min_up_time[f]-1 periods
for f in fossil_units
    for t in 1:length(time_periods)-1
        for tau in t+1 : min(t + min_up_time[f] - 1, length(time_periods))
            @constraint(model, on[f,t] - on[f,t-1] <= on[f,tau])  # if turning on at t, stay on
        end
    end
end
#   If a unit turns off at time t, it must stay off for next min_down_time[f]-1 periods
for f in fossil_units
    for t in 1:length(time_periods)-1
        for tau in t+1 : min(t + min_down_time[f] - 1, length(time_periods))
            @constraint(model, on[f,t-1] - on[f,t] <= 1 - on[f,tau])  # if turning off at t, stay off
        end
    end
end

# 6) Ramp constraints for fossil
for f in fossil_units
    for t in 2:length(time_periods)
        @constraint(model, gen[f,t] - gen[f,t-1] <= ramp_limit[f])
        @constraint(model, gen[f,t-1] - gen[f,t] <= ramp_limit[f])
    end
end

# 7) Spinning reserve constraint:
#   (Online capacity minus actual generation) + (unused battery discharge capacity)
#   must meet reserve_fraction * demand[t]
@constraint(model, [t in time_periods],
    sum(on[f,t]*fossil_capacity[f] - gen[f,t] for f in fossil_units) 
    + (charge_discharge_limit - discharge[t]) 
    >= reserve_fraction * demand[t]
)

# 8) Emission limit for all fossil units
@constraint(model, 
    sum(emission_factor_fossil[f]*gen[f,t] for f in fossil_units, t in time_periods) 
    <= emission_cap
)

# --- Solve ---
optimize!(model)

# --- Print Results ---
println("Status: ", termination_status(model))
println("Optimal Total Cost = ", objective_value(model))

for t in time_periods
    println("Hour $t:")
    for f in fossil_units
        println("   FossilUnit$f On=", value(on[f,t]), 
                " Gen=", round(value(gen[f,t]), digits=2), " MW")
    end
    println("   Renewables=", round(value(ren[t]), digits=2), " MW",
            "  Battery Stored=", round(value(stored[t]), digits=2), " MWh",
            "  Charge=", round(value(charge[t]), digits=2), 
            "  Discharge=", round(value(discharge[t]), digits=2))
end
