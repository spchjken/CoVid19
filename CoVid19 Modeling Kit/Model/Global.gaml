/***
* Part of the GAMA CoVid19 Modeling Kit
* see http://gama-platform.org/covid19
* Author: Benoit Gaudou, Damien Philippon, Patrick Taillandier
* Tags: covid19,epidemiology
***/

@no_experiment

model CoVid19

import "Entities/Building.gaml"
import "Entities/Individual.gaml"
import "Entities/Hospital.gaml"
import "Entities/Activity.gaml"
import "Entities/Boundary.gaml"
import "Entities/Authority.gaml"
import "Entities/Activity.gaml"
import "Entities/Policy.gaml"
import "Constants.gaml"
import "Parameters.gaml"
import "Synthetic Population.gaml"

global {
	geometry shape <- envelope(shp_buildings);
	outside the_outside;
	map<int,map<string,list<string>>> map_epidemiological_parameters;
	action global_init {
		
		write "global init";
		if (shp_boundary != nil) {
			create Boundary from: shp_boundary;
		}
		if (shp_buildings != nil) {
			create Building from: shp_buildings with: [type::string(read(type_shp_attribute)), nb_households::max(1,int(read(flat_shp_attribute)))];
		}
		
		loop aBuilding_Type over: Building collect(each.type)
		{
			add 0 at: aBuilding_Type to: building_infections;
		}
		create outside;
		the_outside <- first(outside);
		do create_activities;
		
		list<Building> homes <- Building where (each.type in possible_homes);
		map<string,list<Building>> buildings_per_activity <- Building group_by (each.type);
		
		map<Building,float> working_places;
		loop wp over: possible_workplaces.keys {
			if (wp in buildings_per_activity.keys) {
					working_places <- working_places +  (buildings_per_activity[wp] as_map (each:: (each.shape.area * possible_workplaces[wp])));  
			}
		}
		
		int min_student_age <- retirement_age;
		int max_student_age <- 0;
		map<list<int>,list<Building>> schools;
		loop l over: possible_schools.keys {
			max_student_age <- max(max_student_age, max(l));
			min_student_age <- min(min_student_age, min(l));
			string type <- possible_schools[l];
			schools[l] <- (type in buildings_per_activity.keys) ? buildings_per_activity[type] : list<Building>([]);
		}
			
		if(csv_population != nil) {
			do create_population_from_file(working_places, schools, homes);
		} else {
			do create_population(working_places, schools, homes, min_student_age, max_student_age);
		}
		do assign_school_working_place(working_places,schools, min_student_age, max_student_age);
		
		map<Building, list<Individual>> WP<- (Individual where (each.working_place != nil)) group_by each.working_place;
		map<Building, list<Individual>> Sc<- (Individual where (each.school != nil)) group_by each.school;
		ask Individual {
			do initialize(WP, Sc);
		}
		
		do define_agenda(min_student_age, max_student_age);	

		ask num_infected_init among Individual {
			do defineNewCase;
		}
		
		total_number_individual <- length(Individual);

	}


	// Inputs
	//   working_places : map associating to each Building a weight (= surface * coefficient for this type of building to be a working_place)
	//   schools :  map associating with each school Building its area (as a weight of the number of students that can be in the school)
	//   min_student_age : minimum age to be in a school
	//   max_student_age : maximum age to go to a school
	action assign_school_working_place(map<Building,float> working_places,map<list<int>,list<Building>> schools, int min_student_age, int max_student_age) {
		
		// Assign to each individual a school and working_place depending of its age.
		// in addition, school and working_place can be outside.
		// Individuals too young or too old, do not have any working_place or school 
		ask Individual {
			last_activity <-first(staying_home);
			do enter_building(home);
			if (age >= min_student_age) {
				if (age <= max_student_age) {
					loop l over: schools.keys {
						if (age >= min(l) and age <= max(l)) {
							if (flip(proba_go_outside) or empty(schools[l])) {
								school <- the_outside;	
							} else {
								switch choice_of_target_mode {
									match random {
										school <- one_of(schools[l]);
									}
									match closest {
										school <- schools[l] closest_to self;
									}
									match gravity {
										list<float> proba_per_building;
										loop b over: schools[l] {
											float dist <- max(20,b.location distance_to home.location);
											proba_per_building << (b.shape.area / dist ^ gravity_power);
										}
										school <- schools[l][rnd_choice(proba_per_building)];	
									}
								}
								
							}
						}
					}
				} else if (age <= retirement_age) { 
					if flip(work_at_home_unemployed) {
						working_place <- home;
					}
					else if (flip(proba_go_outside) or empty(working_places)) {
						working_place <- the_outside;	
					} else {
						switch choice_of_target_mode {
							match random {
								working_place <- working_places.keys[rnd_choice(working_places.values)];
								
							}
							match closest {
								working_place <- working_places.keys closest_to self;
							}
							match gravity {
								list<float> proba_per_building;
								loop b over: working_places.keys {
									float dist <-  max(20,b.location distance_to home.location);
									proba_per_building << (working_places[b]  / (dist ^ gravity_power));
								}
								working_place <- working_places.keys[rnd_choice(proba_per_building)];	
							}
						}
					}
					
				}
			}
		}		
	}
	
	
	// Inputs
	//   min_student_age : minimum age to be in a school
	//   max_student_age : maximum age to go to a school
	// 
	// Principles: each individual has a week agenda composed by 7 daily agendas (maps of hour::Activity).
	//             The agenda depends on the age (students/workers, retired and young children).
	//             Students and workers have an agenda with 6 working days and one leisure days.
	//             Retired have an agenda full of leisure days.
	action define_agenda(int min_student_age, int max_student_age) {
		list<Activity> possible_activities_tot <- Activities.values - studying - working - staying_home;
		list<Activity> possible_activities_without_rel <- possible_activities_tot - visiting_friend;
		Activity eating_act <- Activity first_with (each.name = act_eating);
		ask Individual {
			loop times: 7 {agenda_week<<[];}
		}
		// Initialization for students or workers
		ask Individual where ((each.age <= retirement_age) and (each.age >= min_student_age))  {
			// Students and workers have an agenda similar for 6 days of the week ...
			loop i over: ([1,2,3,4,5,6,7] - non_working_days) {
				map<int,pair<Activity,list<Individual>>> agenda_day <- agenda_week[i - 1];
				list<Activity> possible_activities <- empty(friends) ? possible_activities_without_rel : possible_activities_tot;
				int current_hour;
				if (age <= max_student_age) {
					current_hour <- rnd(school_hours[0][0],school_hours[0][1]);
					agenda_day[current_hour] <- studying[0]::[];
				} else {
					current_hour <-rnd(work_hours[0][0],work_hours[0][1]);
					agenda_day[current_hour] <- working[0]::[];
				}
				bool already <- false;
				loop h from: lunch_hours[0] to: lunch_hours[1] {
					if (h in agenda_day.keys) {
						already <- true;
						break;
					}
				}
				if not already {
					if (flip(proba_lunch_outside_workplace)) {
						current_hour <- rnd(lunch_hours[0],lunch_hours[1]);
						int dur <- rnd(1,2);
						if (not flip(proba_lunch_at_home) and (eating_act != nil) and not empty(eating_act.buildings)) {
							list<Individual> inds <- max(0,gauss(nb_activity_fellows_mean,nb_activity_fellows_std)) among colleagues;
							loop ind over: inds {
								map<int,pair<Activity,list<Individual>>> agenda_day_ind <- ind.agenda_week[i - 1];
								agenda_day_ind[current_hour] <- eating_act::(inds - ind + self);
								if (ind.age <= max_student_age) {
									agenda_day_ind[current_hour + dur] <- studying[0]::[];
								} else {
									agenda_day_ind[current_hour + dur] <- working[0]::[];
								}
							}
							agenda_day[current_hour] <- eating_act::inds ;
						} else {
							agenda_day[current_hour] <- staying_home[0]::[];
						}
						current_hour <- current_hour + dur;
						if (age <= max_student_age) {
							agenda_day[current_hour] <- studying[0]::[];
						} else {
							agenda_day[current_hour] <- working[0]::[];
						}
					}
				}
				if (age <= max_student_age) {
					current_hour <- rnd(school_hours[1][0],school_hours[1][1]);
				} else {
					current_hour <-rnd(work_hours[1][0],work_hours[1][1]);
				}
				agenda_day[current_hour] <- staying_home[0]::[];
				
				already <- false;
				loop h2 from: current_hour to: 23 {
					if (h2 in agenda_day.keys) {
						already <- true;
						break;
					}
				}
				if not already and (age >= min_age_for_evening_act) and flip(proba_activity_evening) {
					current_hour <- current_hour + rnd(1,max_duration_lunch);
					Activity act <- any(possible_activities);
					int current_hour <- min(23,current_hour + rnd(1,max_duration_default));
					int end_hour <- min(23,current_hour + rnd(1,max_duration_default));
					if (species(act) = Activity) {
						list<Individual> inds <- max(0,gauss(nb_activity_fellows_mean,nb_activity_fellows_std)) among friends;
						loop ind over: inds {
							map<int,pair<Activity,list<Individual>>> agenda_day_ind <- ind.agenda_week[i - 1];
							agenda_day_ind[current_hour] <- act::(inds - ind + self);
							agenda_day[end_hour] <- staying_home[0]::[];
						}
						agenda_day[current_hour] <- act::inds;
					} else {
						agenda_day[current_hour] <- act::[];
					}
					agenda_day[end_hour] <- staying_home[0]::[];
				}
				agenda_week[i-1] <- agenda_day;
			}
			
			// ... but it is diferent for non working days : they will pick activities among the ones that are not working, studying or staying home.
			loop i over: non_working_days {
				ask myself {do manag_day_off(myself,i,possible_activities_without_rel,possible_activities_tot);}
			}
			
		}
		
		// Initialization for retired individuals
		loop ind over: Individual where (each.age > retirement_age) {
			loop i from:1 to: 7 {
				do manag_day_off(ind,i,possible_activities_without_rel,possible_activities_tot);
			}
		}
		
	
		
		if (choice_of_target_mode = gravity) {
			ask Individual {
				list<Activity> acts <- remove_duplicates((agenda_week accumulate each.values) collect each.key) inter list(Activity) ;
				loop act over: acts {
					if length(act.buildings) <= nb_candidates {
						building_targets[act] <- act.buildings;
					} else {
						list<Building> bds;
						list<float> proba_per_building;
						loop b over: act.buildings {
							float dist <- max(20,b.location distance_to home.location);
							proba_per_building << (b.shape.area / dist ^ gravity_power);
						}
						loop while: length(bds) < nb_candidates {
							bds << act.buildings[rnd_choice(proba_per_building)];
							bds <- remove_duplicates(bds);
						}
						building_targets[act] <- bds;
					}
				}
			}
		}
		
		
	}
	
	
	action manag_day_off(Individual current_ind, int day, list<Activity> possible_activities_without_rel, list<Activity> possible_activities_tot) {
		map<int,pair<Activity,list<Individual>>> agenda_day <- current_ind.agenda_week[day - 1];
		list<Activity> possible_activities <- empty(current_ind.friends) ? possible_activities_without_rel : possible_activities_tot;
		int num_activity <- rnd(0,max_num_activity_for_non_working_day) - length(agenda_day);
		if (num_activity > 0) {
			list<int> forbiden_hours;
			bool act_beg <- false;
			int beg_act <- 0;
			loop h over: agenda_day.keys sort_by each {
				if not (act_beg) {
					act_beg <- true;
					beg_act <- h;
				} else {
					act_beg <- false;
					loop i from: beg_act to:h {
						forbiden_hours <<i;
					}
				}
			}
			int current_hour <- rnd(first_act_hour_non_working[0],first_act_hour_non_working[1]);
			loop times: num_activity {
				if (current_hour in forbiden_hours) {
					current_hour <- current_hour + 1;
					if (current_hour > 22) {
						break;
					} 
				}
				
				int end_hour <- min(23,current_hour + rnd(1,max_duration_default));
				if (end_hour in forbiden_hours) {
					end_hour <- forbiden_hours first_with (each > current_hour) - 1;
				}
				if (current_hour >= end_hour) {
					break;
				}
				Activity act <- any(possible_activities);
				if (species(act) = Activity) {
					list<Individual> inds <- max(0,gauss(nb_activity_fellows_mean,nb_activity_fellows_std)) among current_ind.friends;
					loop ind over: inds {
						map<int,pair<Activity,list<Individual>>> agenda_day_ind <- ind.agenda_week[day - 1];
						agenda_day_ind[current_hour] <- act::(inds - ind + current_ind);
						agenda_day[end_hour] <- staying_home[0]::[];
					}
					agenda_day[current_hour] <- act::inds;
				} else {
					agenda_day[current_hour] <- act::[];
				}
				agenda_day[end_hour] <- staying_home[0]::[];
				current_hour <- end_hour + 1;
			}
		}
		current_ind.agenda_week[day-1] <- agenda_day;
	}
	
	action init_epidemiological_parameters
	{
		if(load_epidemiological_parameter_from_file and file_exists(epidemiological_parameters))
		{
			csv_parameters <- csv_file(epidemiological_parameters,true);
			matrix data <- matrix(csv_parameters);
			map<string, list<int>> map_parameters;
			list possible_parameters <- distinct(data column_at epidemiological_csv_column_name);
			loop i from: 0 to: data.rows-1{
				if(contains(map_parameters.keys, data[epidemiological_csv_column_name,i] ))
				{
					add i to: map_parameters[string(data[epidemiological_csv_column_name,i])];
				}
				else
				{
					list<int> tmp_list;
					add i to: tmp_list;
					add tmp_list to: map_parameters at: string(data[epidemiological_csv_column_name,i]);
				}
			}
			loop aKey over: map_parameters.keys {
				switch aKey{
					match epidemiological_transmission_human{
						transmission_human <- bool(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])])!=nil?bool(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])]):transmission_human;
					}
					match epidemiological_transmission_building{
						transmission_building <- bool(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])])!=nil?bool(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])]):transmission_building;
					}
					match epidemiological_basic_viral_decrease{
						basic_viral_decrease <- float(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])])!=nil?float(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])]):basic_viral_decrease;
					}
					match epidemiological_successful_contact_rate_building{
						successful_contact_rate_building <- float(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])])!=nil?float(data[epidemiological_csv_column_parameter_one,first(map_parameters[aKey])]):successful_contact_rate_building;
					}
					default{
						loop i from: 0 to:length(map_parameters[aKey])-1
						{
							int index_column <- map_parameters[aKey][i];
							list<string> tmp_list <- list(string(data[epidemiological_csv_column_detail,index_column]),string(data[epidemiological_csv_column_parameter_one,index_column]),string(data[epidemiological_csv_column_parameter_two,index_column]));
							if(i=length(map_parameters[aKey])-1)
							{
								loop aYear from:int(data[epidemiological_csv_column_age,index_column]) to: max_age
								{
									if(contains(map_epidemiological_parameters.keys,aYear))
									{
										add tmp_list to: map_epidemiological_parameters[aYear] at: string(data[epidemiological_csv_column_name,index_column]);
									}
									else
									{
										map<string, list<string>> tmp_map;
										add tmp_list to: tmp_map at: string(data[epidemiological_csv_column_name,index_column]);
										add tmp_map to: map_epidemiological_parameters at: aYear;
									}
								}
							}
							else
							{
								loop aYear from: int(data[epidemiological_csv_column_age,index_column]) to: int(data[epidemiological_csv_column_age,map_parameters[aKey][i+1]])-1
								{
									if(contains(map_epidemiological_parameters.keys,aYear))
									{
										add tmp_list to: map_epidemiological_parameters[aYear] at: string(data[epidemiological_csv_column_name,index_column]);
									}
									else
									{
										map<string, list<string>> tmp_map;
										add tmp_list to: tmp_map at: string(data[epidemiological_csv_column_name,index_column]);
										add tmp_map to: map_epidemiological_parameters at: aYear;
									}
								}
							}
						}
					}
				}
			}
		}
		else
		{
			loop aYear from:0 to: max_age
			{
				map<string, list<string>> tmp_map;
				add list(epidemiological_fixed,string(successful_contact_rate_human)) to: tmp_map at: epidemiological_successful_contact_rate_human;
				add list(epidemiological_fixed,string(reduction_contact_rate_asymptomatic)) to: tmp_map at: epidemiological_reduction_asymptomatic;
				add list(epidemiological_fixed,string(proportion_asymptomatic)) to: tmp_map at: epidemiological_proportion_asymptomatic;
				add list(epidemiological_fixed,string(proportion_dead_symptomatic)) to: tmp_map at: epidemiological_proportion_death_symptomatic;
				add list(epidemiological_fixed,string(basic_viral_release)) to: tmp_map at: epidemiological_basic_viral_release;
				add list(epidemiological_fixed,string(probability_true_positive)) to: tmp_map at: epidemiological_probability_true_positive;
				add list(epidemiological_fixed,string(probability_true_negative)) to: tmp_map at: epidemiological_probability_true_negative;
				add list(epidemiological_fixed,string(proportion_wearing_mask)) to: tmp_map at: epidemiological_proportion_wearing_mask;
				add list(epidemiological_fixed,string(reduction_contact_rate_wearing_mask)) to: tmp_map at: epidemiological_reduction_wearing_mask;
				add list(distribution_type_incubation,string(parameter_1_incubation),string(parameter_2_incubation)) to: tmp_map at: epidemiological_incubation_period;
				add list(distribution_type_serial_interval,string(parameter_1_serial_interval),string(parameter_2_serial_interval)) to: tmp_map at: epidemiological_serial_interval;
				add list(epidemiological_fixed,string(proportion_hospitalization)) to: tmp_map at: epidemiological_proportion_hospitalization;
				add list(epidemiological_fixed,string(proportion_icu)) to: tmp_map at: epidemiological_proportion_icu;
				add list(distribution_type_onset_to_recovery,string(parameter_1_onset_to_recovery),string(parameter_2_onset_to_recovery)) to: tmp_map at: epidemiological_onset_to_recovery;
				add list(distribution_type_onset_to_hospitalization,string(parameter_1_onset_to_hospitalization),string(parameter_2_onset_to_hospitalization)) to: tmp_map at: epidemiological_onset_to_hospitalization;
				add list(distribution_type_hospitalization_to_ICU,string(parameter_1_hospitalization_to_ICU),string(parameter_2_hospitalization_to_ICU)) to: tmp_map at: epidemiological_hospitalization_to_ICU;
				add list(distribution_type_stay_ICU,string(parameter_1_stay_ICU),string(parameter_2_stay_ICU)) to: tmp_map at: epidemiological_stay_ICU;
				add tmp_map to: map_epidemiological_parameters at: aYear;
			}
		}
		
		loop aParameter over: force_parameters
		{
			list<string> list_value;
			switch aParameter
			{
				match epidemiological_successful_contact_rate_human{
					list_value <- list<string>(epidemiological_fixed,successful_contact_rate_human);
				}
				match epidemiological_reduction_asymptomatic{
					list_value <- list<string>(epidemiological_fixed,reduction_contact_rate_asymptomatic);
				}
				match epidemiological_proportion_asymptomatic{
					list_value <- list<string>(epidemiological_fixed,proportion_asymptomatic);
				}
				match epidemiological_proportion_death_symptomatic{
					list_value <- list<string>(epidemiological_fixed,proportion_dead_symptomatic);
				}
				match epidemiological_basic_viral_release{
					list_value <- list<string>(epidemiological_fixed,basic_viral_release);
				}
				match epidemiological_probability_true_positive{
					list_value <- list<string>(epidemiological_fixed,probability_true_positive);
				}
				match epidemiological_probability_true_negative{
					list_value <- list<string>(epidemiological_fixed,probability_true_negative);
				}
				match epidemiological_proportion_wearing_mask{
					list_value <- list<string>(epidemiological_fixed,proportion_wearing_mask);
				}
				match epidemiological_reduction_wearing_mask{
					list_value <- list<string>(epidemiological_fixed,reduction_contact_rate_wearing_mask);
				}
				match epidemiological_incubation_period{
					list_value <- list<string>(distribution_type_incubation,string(parameter_1_incubation),string(parameter_2_incubation));
				}
				match epidemiological_serial_interval{
					list_value <- list<string>(distribution_type_serial_interval,string(parameter_1_serial_interval));
				}
				match epidemiological_onset_to_recovery{
					list_value <- list<string>(distribution_type_onset_to_recovery,string(parameter_1_onset_to_recovery),string(parameter_2_onset_to_recovery));
				}
				match epidemiological_proportion_hospitalization{
					list_value <- list<string>(epidemiological_fixed,proportion_hospitalization);
				}
				match epidemiological_onset_to_hospitalization{
					list_value <- list<string>(distribution_type_onset_to_hospitalization,string(parameter_1_onset_to_hospitalization),string(parameter_2_onset_to_hospitalization));
				}
				match epidemiological_proportion_icu{
					list_value <- list<string>(epidemiological_fixed,proportion_icu);
				}
				match epidemiological_hospitalization_to_ICU{
					list_value <- list<string>(distribution_type_hospitalization_to_ICU,string(parameter_1_hospitalization_to_ICU),string(parameter_2_hospitalization_to_ICU));
				}
				match epidemiological_stay_ICU{
					list_value <- list<string>(distribution_type_stay_ICU,string(parameter_1_stay_ICU),string(parameter_2_stay_ICU));
				}
				default{
					
				}
				
			}
			if(list_value !=nil)
			{
				loop aYear from:0 to: max_age
				{
					map_epidemiological_parameters[aYear][aParameter] <- list_value;
				}
			}
		}
	}

}