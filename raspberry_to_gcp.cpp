#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <deque>
#include <map>
#include <chrono>
#include <thread>
#include <ctime>
#include <iomanip>
#include <cstdlib>
#include <cstdio>
#include <memory>
#include <cstring>
#include <regex>

// ============================
//         Configuration
// ============================

const std::string LOG_FILE = "p:/LOGGER.GAM"; // mtools path

const std::string MACHINE_NAME = "CDL Line 1 [Gamma]";
const std::string CURRENT_LOCATION = "Coteau-du-Lac";
const std::string LOCATION_INFO = "POINT(-74.1771 45.3053)";

const std::string SERVICE_ACCOUNT_FILE = "gf-iot-csr.json";
const std::string PROJECT_ID = "gf-canada-iot";
const std::string DATASET_ID = "GF_CAN_Machines";
const std::string TABLE_ID = "gamma-machines";
const std::string FIRESTORE_COLLECTION = "gamma_machines_status";

// ============================
//       Timezone Mapping
// ============================

std::map<std::string, std::string> TIMEZONES = {
    {"Coteau-du-Lac", "America/Toronto"},
    {"Calmar", "America/Edmonton"}
};

// ============================
//        Function Definitions
// ============================

std::vector<std::string> get_log_lines() {
    std::vector<std::string> lines;
    try {
        std::string command = "mtype " + LOG_FILE;
        std::array<char, 128> buffer;
        std::string result;
        std::shared_ptr<FILE> pipe(popen(command.c_str(), "r"), pclose);
        if (!pipe) {
            std::cerr << "mtype command failed." << std::endl;
            return lines;
        }
        while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
            result += buffer.data();
        }
        std::stringstream ss(result);
        std::string line;
        while (std::getline(ss, line)) {
            lines.push_back(line);
        }
    } catch (...) {
        std::cerr << "mtype command not found. Please install mtools." << std::endl;
    }
    return lines;
}

std::tm parse_time(const std::string& date_str) {
    std::tm tm = {};
    std::istringstream ss(date_str);
    ss >> std::get_time(&tm, "%d-%m-%Y %H:%M:%S");
    return tm;
}

std::map<std::string, std::string> parse_log_line(const std::string& log_line) {
    std::map<std::string, std::string> data;
    std::vector<std::string> values;
    std::stringstream ss(log_line);
    std::string item;
    while (std::getline(ss, item, ';')) {
        values.push_back(item);
    }
    if (values.size() < 17) {
        std::cerr << "Invalid log line: " << log_line << std::endl;
        return data;
    }
    try {
        std::string original_timestamp = values[0];
        std::tm tm = parse_time(original_timestamp);
        time_t time_utc = timegm(&tm);

        // Adjust timezone here if necessary

        char buffer[30];
        strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%S%z", &tm);
        std::string formatted_timestamp(buffer);

        data["Timestamp"] = formatted_timestamp;
        data["Minute ID"] = values[1];
        data["ISO Temp Real"] = values[2];
        data["ISO Temp Set"] = values[3];
        data["RESIN Temp Real"] = values[4];
        data["RESIN Temp Set"] = values[5];
        data["HOSE Temp Real"] = values[6];
        data["HOSE Temp Set"] = values[7];
        data["Value8"] = values[8];
        data["Value9"] = values[9];
        data["ISO Amperage"] = values[10];
        data["RESIN Amperage"] = values[11];
        data["ISO Pressure"] = values[12];
        data["RESIN Pressure"] = values[13];
        data["Counter"] = values[14];
        data["Value15"] = values[15];
        data["Status"] = values[16];
        data["Machine"] = MACHINE_NAME;
        data["Location"] = LOCATION_INFO;
        data["Location Name"] = CURRENT_LOCATION;
    } catch (...) {
        std::cerr << "Timestamp parse error." << std::endl;
    }
    return data;
}

void send_to_bigquery(const std::map<std::string, std::string>& data) {
    // BigQuery integration code goes here
}

void update_firestore(const std::map<std::string, std::string>& data) {
    // Firestore integration code goes here
}

void process_line(const std::string& last_line, const std::string& new_line) {
    try {
        std::vector<std::string> last_values;
        std::stringstream ss_last(new_line);
        std::string item;
        while (std::getline(ss_last, item, ';')) {
            last_values.push_back(item);
        }

        std::vector<std::string> third_last_values;
        std::stringstream ss_third_last(last_line);
        while (std::getline(ss_third_last, item, ';')) {
            third_last_values.push_back(item);
        }

        int last_digit = std::stoi(last_values[last_values.size() - 2]);
        int third_last_digit = std::stoi(third_last_values[third_last_values.size() - 2]);

        std::string status = (last_digit != third_last_digit && last_digit != 0) ? "Running" : "Stopped";

        std::string new_line_with_status = new_line + ";" + status;

        auto data = parse_log_line(new_line_with_status);

        if (!data.empty()) {
            send_to_bigquery(data);
            update_firestore(data);
        }
    } catch (...) {
        std::cerr << "Line processing error." << std::endl;
    }
}

void continuously_monitor(int interval = 1) {
    std::deque<std::string> last_three;
    while (true) {
        try {
            auto lines = get_log_lines();
            last_three.clear();
            for (const auto& line : lines) {
                last_three.push_back(line);
                if (last_three.size() > 3) {
                    last_three.pop_front();
                }
            }
            if (last_three.size() == 3) {
                process_line(last_three[0], last_three[2]);
            }
        } catch (...) {
            std::cerr << "Monitoring error." << std::endl;
        }
        std::this_thread::sleep_for(std::chrono::seconds(interval));
    }
}

// ============================
//         Main Execution
// ============================

int main() {
    continuously_monitor();
    return 0;
}
