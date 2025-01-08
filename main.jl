using JuMP
using HiGHS

# === Problem Data ===
time_periods = 1:24  # 24-hour optimization horizon
plants = 1:2  # Energy sources (1: Fossil, 2: Renewable)
battery = 1   # Single battery system

# Costs
generation_cost = [50, 0]  # Fossil: $50/MWh, Renewable: $0/MWh
storage_cost = 10          # $10/MWh for charging/discharging

# Capacities
plant_capacity = [100, 80]  # Fossil: 100 MW, Renewable: 80 MW
battery_capacity = 50       # Battery max capacity: 50 MWh
charge_discharge_limit = 20 # Max charge/discharge rate: 20 MW
storage_efficiency = 0.9    # 90% efficiency

# Randomized time-dependent data
renewable_availability = [rand(0:80) for _ in time_periods]
demand = [rand(50:120) for _ in time_periods]

# === Optimization Model ===
model = Model(HiGHS.Optimizer)

@variable(model, 0 <= generation[plants, time_periods])  # Power generated
@variable(model, 0 <= charge[time_periods] <= charge_discharge_limit)
@variable(model, 0 <= discharge[time_periods] <= charge_discharge_limit)
@variable(model, 0 <= stored_energy[time_periods] <= battery_capacity)

# Objective: Minimize total cost
@objective(model, Min, 
    sum(generation_cost[i] * generation[i, t] for i in plants, t in time_periods) +
    storage_cost * sum(charge[t] + discharge[t] for t in time_periods)
)

# Constraints
@constraint(model, [t in time_periods], 
    sum(generation[i, t] for i in plants) + discharge[t] - charge[t] == demand[t]
)
@constraint(model, [i in plants, t in time_periods], 
    generation[i, t] <= (i == 1 ? plant_capacity[i] : renewable_availability[t])
)
@constraint(model, stored_energy[1] == 0)
@constraint(model, [t in 2:length(time_periods)], 
    stored_energy[t] == stored_energy[t-1] + charge[t-1] * storage_efficiency - discharge[t-1] / storage_efficiency
)

# === Solve the Model ===
optimize!(model)

# === Display Results ===
println("=== Optimal Solution ===")
for t in time_periods
    println("Hour $t: Fossil: $(value(generation[1, t])) MW, Renewable: $(value(generation[2, t])) MW, Battery: Stored=$(value(stored_energy[t])) MWh")
end
println("Total Cost: $(objective_value(model))")
